# tools/jobs/apk.Dockerfile - the apk job (compose.yml): targets/android/app's assembleDebug over the baked source.
# The APK comes out at /out/powos.apk signed with this container's throwaway debug key; build-app.sh re-signs it on
# the hub with the shared key (android-keystores), which never leaves the hub.
# Arch-aware (x86_64: native SDK tools; arm64: + amd64 libs for the x86-only aapt2/NDK/CMake, as android-app-dev's
# builder). The SDK parts the app needs are baked, so a run downloads nothing but new Maven deps (into the Gradle
# home volume). Context (staged by build-app.sh): targets/android/app, shell, app/bundled-apps + shell-build.txt
# (gitignored, staged), _powterm/ (android-app-dev/projects/powterm's java).
FROM docker.io/library/eclipse-temurin:17-jdk-jammy
RUN set -e; extra=""; \
    if [ "$(dpkg --print-architecture)" = arm64 ]; then \
      dpkg --add-architecture amd64; \
      sed -i 's/^deb http/deb [arch=arm64] http/' /etc/apt/sources.list; \
      for s in jammy jammy-updates; do echo "deb [arch=amd64] http://archive.ubuntu.com/ubuntu $s main restricted universe" >> /etc/apt/sources.list; done; \
      extra="libc6:amd64 libstdc++6:amd64 zlib1g:amd64"; \
    fi; \
    apt-get update && apt-get install -y --no-install-recommends wget unzip zip git $extra && rm -rf /var/lib/apt/lists/*
ENV ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk
ENV PATH=${PATH}:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/build-tools/36.0.0
RUN mkdir -p /opt/android-sdk/cmdline-tools && cd /opt/android-sdk/cmdline-tools \
    && wget -q https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip -O t.zip \
    && unzip -q t.zip && mv cmdline-tools latest && rm t.zip \
    && (yes | sdkmanager --licenses >/dev/null) \
    && sdkmanager "platform-tools" "platforms;android-36" "platforms;android-37.0" "build-tools;35.0.0" "build-tools;36.0.0" \
         "ndk;28.2.13676358" "cmake;3.22.1" >/dev/null
COPY . /src
ENV POWTERM_SRC=/src/_powterm
WORKDIR /src/targets/android/app
CMD ["bash", "-c", "set -euo pipefail; echo \"sdk.dir=$ANDROID_SDK_ROOT\" > local.properties; printf 'versionCode=%s\\nversionName=%s\\n' \"${VERSION_CODE:?}\" \"${VERSION_NAME:?}\" > app/version.properties; ./gradlew assembleDebug --no-daemon --build-cache --stacktrace -q; apk=$(find app/build/outputs/apk/debug -name '*.apk' | head -1); mkdir -p /out; cp \"$apk\" /out/powos.apk; echo \"apk job: $apk -> /out/powos.apk ($(du -h /out/powos.apk | cut -f1))\""]
