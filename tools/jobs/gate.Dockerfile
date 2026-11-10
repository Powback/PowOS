# tools/jobs/gate.Dockerfile - the gate job (compose.yml): the shell gate's browser half (gate.mjs scenes, shots.mjs
# renders) over the shell shell/dev/gate.sh composed, and dev/preview.sh's widget passes (image tag <checkout>-preview,
# app/ = preview.mjs). Context (staged by gate.sh / preview.sh): shell/ (the composed tree, no node_modules), app/
# (gate.mjs, agents-fleet.mjs, search-check.js, shots.mjs), apps/<id>/ (--app), fonts/, in/.
FROM docker.io/zenika/alpine-chrome:with-puppeteer
USER root
# /targets/.../res/font -> /fonts: where the shell's fonts/nerd_symbols.ttf link points (the preview serves it).
RUN mkdir -p /cache /out /apps /fonts /targets/android/app/app/src/main/res && chown chrome /cache /out \
    && ln -s /in/wallpaper.jpg /wallpaper.jpg && ln -s /fonts /targets/android/app/app/src/main/res/font
COPY shell /shell
COPY apps /apps
COPY fonts /fonts
COPY in /in
COPY app/ /usr/src/app/
USER chrome
WORKDIR /usr/src/app
ENTRYPOINT ["node"]
CMD ["gate.mjs"]
