FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Enable i386, install mingw cross-compiler, set up WineHQ apt repo for wine 10.x
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        wget \
    && mkdir -pm755 /etc/apt/keyrings \
    && wget -nv -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -nv -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources \
    && apt-get update \
    && apt-get install -y --install-recommends winehq-staging \
    && apt-get install -y --no-install-recommends \
        mingw-w64 \
        g++-mingw-w64-x86-64 \
        cabextract \
        p7zip-full \
        make \
        cmake \
        python3 \
        xvfb \
        libgl1-mesa-dri \
        libglu1-mesa \
        libosmesa6 \
        x11-utils \
        poppler-utils \
        blender \
        libegl1 \
    && rm -rf /var/lib/apt/lists/*

# Install winetricks; symlink wine binary on PATH (WineHQ installs in /opt/wine-staging)
RUN curl -sL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
        -o /usr/local/bin/winetricks && chmod +x /usr/local/bin/winetricks && \
    if [ -x /opt/wine-staging/bin/wine ]; then \
        ln -sf /opt/wine-staging/bin/wine /usr/local/bin/wine; \
        ln -sf /opt/wine-staging/bin/wine /usr/local/bin/wine64; \
    fi

# Use posix threads variant of mingw (better C++11 support)
RUN update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix && \
    update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

ENV WINEDEBUG=-all
ENV WINEPREFIX=/wineprefix

WORKDIR /work
