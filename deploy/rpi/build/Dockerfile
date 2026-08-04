# Reproducible aarch64 Flutter GTK build image for the Segno appliance bundle.
# Build + run natively on an arm64 host/runner (Apple Silicon, ubuntu-24.04-arm):
#   docker build -t segno-arm64-build deploy/rpi/build
#   docker run --rm -v "$PWD":/workspace segno-arm64-build --dart-define=SEGNO_CONSOLE=true
# The entrypoint (segno-build.sh) runs `flutter build linux --release`; extra args
# ("$@") are forwarded to it. Output lands in build/linux/arm64/release/bundle.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ninja-build libgtk-3-dev libglib2.0-dev libpango1.0-dev libasound2-dev \
      clang cmake pkg-config \
      git curl unzip xz-utils zip liblzma-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV FLUTTER_HOME=/opt/flutter
RUN git clone --depth 1 --branch 3.44.4 https://github.com/flutter/flutter.git "$FLUTTER_HOME"
ENV PATH=/opt/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN git config --global --add safe.directory '*' \
    && flutter config --enable-linux-desktop \
    && flutter precache --linux

COPY segno-build.sh /usr/local/bin/segno-build
RUN chmod +x /usr/local/bin/segno-build

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/segno-build"]
