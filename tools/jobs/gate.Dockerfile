# tools/jobs/gate.Dockerfile - the gate job (compose.yml): the shell gate's browser half (gate.mjs scenes, shots.mjs
# renders) over the shell shell/dev/gate.sh composed. Context (staged by gate.sh): shell/ (the composed tree, no
# node_modules), app/ (gate.mjs, agents-fleet.mjs, search-check.js, shots.mjs), apps/<id>/ (--app), fonts/, in/.
FROM docker.io/zenika/alpine-chrome:with-puppeteer
USER root
RUN mkdir -p /cache /out /apps /fonts && chown chrome /cache /out && ln -s /in/wallpaper.jpg /wallpaper.jpg
COPY shell /shell
COPY apps /apps
COPY fonts /fonts
COPY in /in
COPY app/ /usr/src/app/
USER chrome
WORKDIR /usr/src/app
ENTRYPOINT ["node"]
CMD ["gate.mjs"]
