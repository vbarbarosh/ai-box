# syntax=docker/dockerfile:1

# npm's metadata for the two CLIs. Each stage carries one release number, and
# it is the cache key of the matching every-build layer at the end of the file.
FROM ubuntu:24.04 AS refresh-claude

ADD https://registry.npmjs.org/@anthropic-ai%2Fclaude-code/latest /claude/package.json
RUN chmod 0444 /claude/package.json

FROM ubuntu:24.04 AS refresh-codex

ADD https://registry.npmjs.org/@openai%2Fcodex/latest /codex/package.json
RUN chmod 0444 /codex/package.json

# =============================================================================
# Weekly layers
#
# UBUNTU_REFRESH carries one ISO week. It gates the package layer below, and
# every layer under that one inherits the gate. Each layer here asks its own
# upstream for the current version from inside the layer, so a release that
# appears mid-week rebuilds nothing until the token advances.
# =============================================================================

FROM ubuntu:24.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_REFRESH=manual
ARG NODE_VERSION=24.14.1
ARG PLAYWRIGHT_VERSION=1.61.1
ARG PUPPETEER_VERSION=25.3.0
ARG CYPRESS_VERSION=14.2.1
ARG IMAGEMAGICK_VERSION=7.1.2-29
ARG OXIPNG_VERSION=10.2.0
ARG WHISPER_MODEL=small

ENV NPM_CONFIG_PREFIX=/home/ubuntu/.local \
    NODE_PATH=/home/ubuntu/.local/lib/node_modules \
    PATH=/home/ubuntu/bin:/home/ubuntu/.local/bin:${PATH} \
    PLAYWRIGHT_BROWSERS_PATH=/home/ubuntu/.cache/ms-playwright \
    PUPPETEER_CACHE_DIR=/home/ubuntu/.cache/puppeteer \
    CYPRESS_CACHE_FOLDER=/home/ubuntu/.cache/Cypress \
    HF_HOME=/home/ubuntu/.cache/huggingface \
    WHISPER_MODEL=${WHISPER_MODEL}

# Keep distribution packages in one layer. UBUNTU_REFRESH is the only thing
# that expires it, and bin/build advances the token once per UTC week.
# Package archives and indexes stay in BuildKit caches, not the final image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    echo "Ubuntu package refresh: ${UBUNTU_REFRESH}" \
    && mv /etc/apt/apt.conf.d/docker-clean /tmp/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        ethtool \
        exiftran \
        ffmpeg \
        file \
        fonts-inter \
        fonts-lato \
        fonts-noto-color-emoji \
        fonts-noto-core \
        fonts-ubuntu \
        g++ \
        git \
        htop \
        imagemagick \
        iproute2 \
        jq \
        libjpeg-turbo-progs \
        make \
        man \
        mysql-client \
        mysql-server \
        net-tools \
        optipng \
        parallel \
        pciutils \
        php-bcmath \
        php-cli \
        php-curl \
        php-dev \
        php-gd \
        php-gmp \
        php-intl \
        php-mbstring \
        php-mongodb \
        php-mysql \
        php-pear \
        php-soap \
        php-xml \
        php-zip \
        pngcrush \
        pngquant \
        pv \
        python3-pip \
        redis-server \
        ripgrep \
        silversearcher-ag \
        socat \
        tesseract-ocr \
        tesseract-ocr-ron \
        tree \
        unzip \
        vim \
        webp \
        wget \
        zbar-tools \
        zip \
        zopfli \
    && fc-cache -f \
    && fc-match Inter | grep -qi inter \
    && fc-match sans-serif | grep -qi noto \
    && php --version \
    && tesseract --version \
    && zbarimg --version \
    && optipng --version \
    && pngcrush -version \
    && pngquant --version \
    && cwebp -version \
    && zopflipng -h > /dev/null \
    && cjpeg -version \
    && djpeg -version \
    && jpegtran -version \
    && exiftran -h > /dev/null \
    && mv /tmp/docker-clean /etc/apt/apt.conf.d/docker-clean

RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

# buildah re-creates the parent directory of a cache-mount target as root,
# where BuildKit leaves its owner alone. Restore it before dropping to ubuntu,
# or `USER ubuntu` lands in a home directory it cannot write to.
RUN chown ubuntu:ubuntu /home/ubuntu

USER ubuntu

# npm's download cache is retained by BuildKit for later builds but is not
# committed to the image. Browser downloads use their separate runtime caches.
RUN --mount=type=cache,target=/home/ubuntu/.npm,uid=1000,gid=1000 \
    PUPPETEER_SKIP_DOWNLOAD=true npm install --global --no-audit --no-fund \
        "playwright@${PLAYWRIGHT_VERSION}" \
        "puppeteer@${PUPPETEER_VERSION}" \
        "cypress@${CYPRESS_VERSION}" \
    && playwright --version \
    && node -e "console.log('Puppeteer ' + require('puppeteer/package.json').version)" \
    && cypress version

USER root

# Install the pinned browser framework's system dependencies before downloading
# its pinned browser revisions.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    mv /etc/apt/apt.conf.d/docker-clean /tmp/docker-clean \
    && playwright install-deps \
    && mv /tmp/docker-clean /etc/apt/apt.conf.d/docker-clean

# buildah re-creates the parent directory of a cache-mount target as root,
# where BuildKit leaves its owner alone. Restore it before dropping to ubuntu,
# or `USER ubuntu` lands in a home directory it cannot write to.
RUN chown ubuntu:ubuntu /home/ubuntu

USER ubuntu

RUN playwright install chromium firefox webkit \
    && playwright install --list

RUN puppeteer browsers install

RUN cypress verify \
    && cypress info

RUN printf '\n%s\n%s\n' \
        'alias codex="codex -a never -s danger-full-access"' \
        'export PATH="$HOME/bin:$HOME/.local/bin:$PATH"' \
        >> "$HOME/.bashrc"

# OpenCV comes from pip, not apt: rembg's dependencies force numpy 2 into
# ~/.local, which shadows apt numpy and breaks noble's numpy-1-built
# python3-opencv. The model download (~170 MB to ~/.u2net) happens at build time
# so background removal works offline at runtime.
RUN --mount=type=cache,target=/home/ubuntu/.cache/pip,uid=1000,gid=1000 \
    opencv_version="$(curl -fsSL https://pypi.org/pypi/opencv-python-headless/json | jq -r .info.version)" \
    && rembg_version="$(curl -fsSL https://pypi.org/pypi/rembg/json | jq -r .info.version)" \
    && python3 -m pip install --user --break-system-packages \
        "opencv-python-headless==${opencv_version}" \
        "rembg[cpu,cli]==${rembg_version}" \
    && python3 -c "from rembg import new_session; new_session()" \
    && python3 -c "import cv2, numpy; print('OpenCV', cv2.__version__, '/ numpy', numpy.__version__)" \
    && rembg --help > /dev/null

# QR, OCR, and speech-synthesis libraries for ad-hoc node scripts (NODE_PATH
# points here). msedge-tts speaks screencast narration through the Edge voices;
# it needs network at runtime, and writes into a directory that must exist. Its
# published preinstall hook (`npx only-allow pnpm`) rejects every other package
# manager, so it installs with scripts off; the package builds nothing at
# install time.
RUN --mount=type=cache,target=/home/ubuntu/.npm,uid=1000,gid=1000 \
    zxing_version="$(curl -fsSL https://registry.npmjs.org/@zxing%2Flibrary/latest | jq -r .version)" \
    && jsqr_version="$(curl -fsSL https://registry.npmjs.org/jsqr/latest | jq -r .version)" \
    && msedge_tts_version="$(curl -fsSL https://registry.npmjs.org/msedge-tts/latest | jq -r .version)" \
    && tesseract_version="$(curl -fsSL https://registry.npmjs.org/tesseract.js/latest | jq -r .version)" \
    && npm install --global --no-audit --no-fund \
        "@zxing/library@${zxing_version}" \
        "jsqr@${jsqr_version}" \
        "tesseract.js@${tesseract_version}" \
    && npm install --global --no-audit --no-fund --ignore-scripts "msedge-tts@${msedge_tts_version}" \
    && node -e "require('jsqr'); require('@zxing/library'); require('msedge-tts'); console.log('jsqr + zxing + msedge-tts ok')"

# Speech in a recording is unreadable without transcription: faster-whisper
# turns an audio or video track into text. CTranslate2 runs it on the CPU
# without torch, PyAV reads .mp4/.webm/.mkv directly, and the model (~464 MB
# for small) is fetched at build time so transcription works offline. Build
# with --build-arg WHISPER_MODEL=base for a smaller, less accurate one.
RUN --mount=type=cache,target=/home/ubuntu/.cache/pip,uid=1000,gid=1000 \
    faster_whisper_version="$(curl -fsSL https://pypi.org/pypi/faster-whisper/json | jq -r .info.version)" \
    && python3 -m pip install --user --break-system-packages \
        "faster-whisper==${faster_whisper_version}" \
    && ffmpeg -nostdin -v error -f lavfi -i sine=frequency=440:sample_rate=16000 -t 1 -y /tmp/probe.wav \
    && python3 -c "from faster_whisper import WhisperModel; model = WhisperModel('${WHISPER_MODEL}', device='cpu', compute_type='int8'); segments, info = model.transcribe('/tmp/probe.wav'); list(segments); print('faster-whisper ${WHISPER_MODEL}', info.language)" \
    && rm /tmp/probe.wav

USER root

# Ubuntu ships phpredis 5.3.7, which throws "Redis server went away" when
# Redis::setOption() is called before connect(). Applications that set options
# on a fresh client need 6.x, so build the current PECL release.
RUN redis_version="$(curl -fsSL https://pecl.php.net/rest/r/redis/latest.txt | tr -d '[:space:]')" \
    && yes '' | pecl install "redis-${redis_version}" \
    && php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')" \
    && echo extension=redis.so > "/etc/php/${php_version}/mods-available/redis.ini" \
    && phpenmod redis \
    && php -r 'exit(extension_loaded("redis") ? 0 : 1);' \
    && php -r 'echo "phpredis ", phpversion("redis"), PHP_EOL;' \
    && rm -rf /tmp/pear

RUN composer_version="$(curl -fsSL https://getcomposer.org/versions | jq -r '.stable[0].version')" \
    && curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php \
    && php /tmp/composer-setup.php \
        --version="${composer_version}" \
        --install-dir=/usr/local/bin \
        --filename=composer \
    && rm /tmp/composer-setup.php \
    && composer --version

# The published checksum arrives before the binary it describes, so a release
# that lands between the two downloads fails the check instead of passing it.
RUN curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio.sha256sum -o /tmp/minio.sha256sum \
    && curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc.sha256sum -o /tmp/mc.sha256sum \
    && curl -fsSL https://dl.min.io/server/minio/release/linux-amd64/minio -o /usr/local/bin/minio \
    && curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc \
    && echo "$(cut -d ' ' -f 1 /tmp/minio.sha256sum)  /usr/local/bin/minio" | sha256sum -c - \
    && echo "$(cut -d ' ' -f 1 /tmp/mc.sha256sum)  /usr/local/bin/mc" | sha256sum -c - \
    && rm /tmp/minio.sha256sum /tmp/mc.sha256sum \
    && chmod 0755 /usr/local/bin/minio /usr/local/bin/mc \
    && minio --version \
    && mc --version

RUN curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS -o /tmp/SHA2-256SUMS \
    && curl -fsSL https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
    && (cd /usr/local/bin && grep '  yt-dlp$' /tmp/SHA2-256SUMS | sha256sum -c -) \
    && rm /tmp/SHA2-256SUMS \
    && chmod 0755 /usr/local/bin/yt-dlp \
    && yt-dlp --version

# oxipng is absent from the Ubuntu archive, so it comes from the project's own
# release. GitHub publishes each asset's digest next to the download, so the
# tarball is verified without a checksum copied into this file.
RUN oxipng_dir="oxipng-${OXIPNG_VERSION}-x86_64-unknown-linux-musl" \
    && oxipng_digest="$(curl -fsSL "https://api.github.com/repos/oxipng/oxipng/releases/tags/v${OXIPNG_VERSION}" | jq -r --arg name "${oxipng_dir}.tar.gz" '.assets[] | select(.name == $name) | .digest // empty')" \
    && test -n "${oxipng_digest}" \
    && curl -fsSL "https://github.com/oxipng/oxipng/releases/download/v${OXIPNG_VERSION}/${oxipng_dir}.tar.gz" -o /tmp/oxipng.tar.gz \
    && echo "${oxipng_digest#sha256:}  /tmp/oxipng.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/oxipng.tar.gz -C /usr/local/bin --strip-components=1 "${oxipng_dir}/oxipng" \
    && rm /tmp/oxipng.tar.gz \
    && oxipng --version

# Ubuntu 24.04 ships ImageMagick 6, which answers to `convert` and has no
# `magick` command. The upstream AppImage puts ImageMagick 7 beside it: the
# container has no FUSE, so the image is unpacked, and only `magick` reaches
# PATH, leaving every ImageMagick 6 command in place. The probe conversion
# proves the unpacked tree finds its own coders.
RUN magick_asset="ImageMagick-${IMAGEMAGICK_VERSION}-gcc-x86_64.AppImage" \
    && magick_digest="$(curl -fsSL "https://api.github.com/repos/ImageMagick/ImageMagick/releases/tags/${IMAGEMAGICK_VERSION}" | jq -r --arg name "${magick_asset}" '.assets[] | select(.name == $name) | .digest // empty')" \
    && test -n "${magick_digest}" \
    && curl -fsSL "https://github.com/ImageMagick/ImageMagick/releases/download/${IMAGEMAGICK_VERSION}/${magick_asset}" -o /tmp/magick.AppImage \
    && echo "${magick_digest#sha256:}  /tmp/magick.AppImage" | sha256sum -c - \
    && chmod 0755 /tmp/magick.AppImage \
    && cd /opt \
    && /tmp/magick.AppImage --appimage-extract > /dev/null \
    && mv /opt/squashfs-root /opt/imagemagick \
    && rm /tmp/magick.AppImage \
    && ln -s /opt/imagemagick/AppRun /usr/local/bin/magick \
    && magick -version \
    && magick -size 8x8 gradient:red-blue /tmp/probe.webp \
    && rm /tmp/probe.webp

# The container engine, daemon NOT included. Podman is daemonless and runs
# unprivileged, so the environment needs neither --privileged nor a bound-in
# socket, and nothing has to boot before the shell is usable. `podman-docker`
# installs a real `docker` command, so tooling inside is unchanged.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        aardvark-dns \
        buildah \
        crun \
        fuse-overlayfs \
        iptables \
        libcap2-bin \
        netavark \
        nftables \
        passt \
        podman \
        podman-compose \
        podman-docker \
        slirp4netns \
        uidmap \
    && docker --version \
    && podman --version

# Ubuntu ships newuidmap/newgidmap setuid-root; Fedora ships them with file
# capabilities. Only the capability form can write a NESTED uid_map, which is
# what the inner engine needs when it re-execs itself into a user namespace.
# Without this the inner `docker` dies with "newuidmap: ... Operation not
# permitted". This is the one Ubuntu-specific trap in the whole setup.
RUN setcap cap_setuid+ep /usr/bin/newuidmap \
    && setcap cap_setgid+ep /usr/bin/newgidmap \
    && chmod u-s /usr/bin/newuidmap /usr/bin/newgidmap

# A subordinate range for `ubuntu`, carved out of the range the OUTER rootless
# container already maps. 1000 is skipped because that is ubuntu itself.
RUN printf 'ubuntu:1:999\nubuntu:1001:64535\n' > /etc/subuid \
    && printf 'ubuntu:1:999\nubuntu:1001:64535\n' > /etc/subgid

# A drop-in, not a replacement: overwriting /etc/containers/containers.conf
# discards the distro's own settings (helper binary paths among them) and the
# inner engine then cannot find netavark.
COPY --chown=0:0 --chmod=0644 files/containers/99-nested.conf /etc/containers/containers.conf.d/99-nested.conf
COPY --chown=0:0 --chmod=0644 files/containers/storage.conf    /etc/containers/storage.conf
COPY --chown=0:0 --chmod=0644 files/containers/registries.conf /etc/containers/registries.conf
RUN touch /etc/containers/nodocker

# No `usermod -aG docker ubuntu`: there is no daemon and no socket to be
# granted access to. Membership in a docker group was itself root-equivalent.

# Chrome is the largest weekly-moving system package, so keep it near the end.
# Its repository metadata supplies the exact version used to verify the
# downloaded package.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    curl -fsSL https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages -o /tmp/Packages \
    && chrome_version="$(awk '/^Package: google-chrome-stable$/ { stable=1 } stable && /^Version:/ { print $2; exit }' /tmp/Packages)" \
    && chrome_filename="$(awk '/^Package: google-chrome-stable$/ { stable=1 } stable && /^Filename:/ { print $2; exit }' /tmp/Packages)" \
    && chrome_sha256="$(awk '/^Package: google-chrome-stable$/ { stable=1 } stable && /^SHA256:/ { print $2; exit }' /tmp/Packages)" \
    && test -n "${chrome_version}" \
    && test -n "${chrome_filename}" \
    && test -n "${chrome_sha256}" \
    && mv /etc/apt/apt.conf.d/docker-clean /tmp/docker-clean \
    && apt-get update \
    && curl -fsSL "https://dl.google.com/linux/chrome/deb/${chrome_filename}" -o /tmp/google-chrome.deb \
    && echo "${chrome_sha256}  /tmp/google-chrome.deb" | sha256sum -c - \
    && apt-get install -y --no-install-recommends /tmp/google-chrome.deb \
    && test "$(dpkg-query -W -f='${Version}' google-chrome-stable)" = "${chrome_version}" \
    && rm /tmp/google-chrome.deb /tmp/Packages \
    && google-chrome --version \
    && mv /tmp/docker-clean /etc/apt/apt.conf.d/docker-clean

# Times shown by the shell, by build tools, and by recorded output are the local
# times of the people reading them. tzdata arrives with the packages above, so
# only the machine-wide selection is left to make.
ENV TZ=Europe/Chisinau

RUN ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && date

# buildah re-creates the parent directory of a cache-mount target as root,
# where BuildKit leaves its owner alone. Restore it before dropping to ubuntu,
# or `USER ubuntu` lands in a home directory it cannot write to.
RUN chown ubuntu:ubuntu /home/ubuntu

USER ubuntu

# =============================================================================
# Every-build layers
#
# The refresh stages at the top of the file read npm on every build, so these
# two layers follow a CLI release the day it appears. They are last and cheap:
# a new Claude or Codex costs seconds and leaves every layer above untouched.
# =============================================================================

RUN --mount=type=bind,from=refresh-claude,source=/claude,target=/tmp/refresh \
    CLAUDE_VERSION="$(jq -r .version /tmp/refresh/package.json)" \
    && echo "Installing Claude ${CLAUDE_VERSION}..." \
    && curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}" \
    && "$HOME/.local/bin/claude" --version

RUN --mount=type=bind,from=refresh-codex,source=/codex,target=/tmp/refresh \
    --mount=type=cache,target=/home/ubuntu/.npm,uid=1000,gid=1000 \
    CODEX_VERSION="$(jq -r .version /tmp/refresh/package.json)" \
    && echo "Installing Codex ${CODEX_VERSION}..." \
    && npm install --global --no-audit --no-fund "@openai/codex@${CODEX_VERSION}" \
    && codex --version \
    && mkdir -p "$HOME/.codex"

# COPY defaults to root ownership even though the current runtime user is
# ubuntu. Keeping local content last prevents edits from invalidating downloads.
#
# The whole directory goes to ~/bin, which the PATH above already carries, so
# every helper here is on the PATH without a COPY per script.
COPY --chown=1000:1000 --chmod=0755 files/bin/ /home/ubuntu/bin/

# Tools the assistant reaches for: `tts` speaks narration, `transcribe` reads it
# back out of a recording.
COPY --chown=0:0 --chmod=0755 files/bin.ai/ /usr/local/bin/

# Late, with the other local content, so editing it does not invalidate the
# downloads above.
RUN install -d -o ubuntu -g ubuntu -m 0755 /home/ubuntu/.config/containers
COPY --chown=1000:1000 --chmod=0644 files/containers/storage-user.conf /home/ubuntu/.config/containers/storage.conf

USER root

# The mountpoint for the read-only shared image store. Both storage configs
# name it, so it has to exist even when nothing is mounted over it -- otherwise
# the inner engine refuses to start with "can't stat imageStore dir".
RUN mkdir -p /var/lib/shared/overlay-images \
             /var/lib/shared/overlay-layers \
             /var/lib/shared/overlay-containers \
 && touch /var/lib/shared/overlay-images/images.lock \
          /var/lib/shared/overlay-layers/layers.lock \
          /var/lib/shared/overlay-containers/containers.lock

# Also set here, not only in the entrypoint: a `podman exec` into a running
# environment does not pass through the entrypoint, and an inner engine with no
# runtime directory drops its pause-process file into $PWD -- which is /app,
# the mounted host workspace.
ENV XDG_RUNTIME_DIR=/run/user/1000

COPY --chmod=0755 files/docker-entrypoint /usr/local/bin/docker-entrypoint
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
CMD ["bash"]
