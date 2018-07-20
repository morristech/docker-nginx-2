#!/bin/bash
set -e

install_packages() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

download_and_extract() {
  src=${1}
  dest=${2}
  tarball=$(basename ${src})

  if [[ ! -f ${NGINX_BUILD_ASSETS_DIR}/${tarball} ]]; then
    echo "Downloading ${1}..."
    wget ${src} -O ${NGINX_BUILD_ASSETS_DIR}/${tarball}
  fi

  echo "Extracting ${tarball}..."
  mkdir ${dest}
  tar xf ${NGINX_BUILD_ASSETS_DIR}/${tarball} --strip=1 -C ${dest}
}

strip_debug() {
  local dir=${1}
  local filter=${2}
  for f in $(find "${dir}" -name "${filter}")
  do
    if [[ -f ${f} ]]; then
      strip --strip-all ${f}
    fi
  done
}

${WITH_RTMP} && {
  # download_and_extract "https://sourceforge.net/projects/opencore-amr/files/fdk-aac/fdk-aac-${FDK_AAC_VERSION}.tar.gz" "${NGINX_BUILD_ASSETS_DIR}/fdk-aac"
  download_and_extract "http://prdownloads.sourceforge.net/opencore-amr/fdk-aac-${FDK_AAC_VERSION}.tar.gz" "${NGINX_BUILD_ASSETS_DIR}/fdk-aac"
  cd ${NGINX_BUILD_ASSETS_DIR}/fdk-aac
  ./configure \
    --prefix=/usr \
    --enable-shared \
    --disable-static \
    --disable-example
  make -j$(nproc)
  make install
  make DESTDIR=${NGINX_BUILD_ROOT_DIR} install

  install_packages yasm
  download_and_extract "http://ftp.videolan.org/pub/x264/snapshots/x264-${X264_VERSION}.tar.bz2" "${NGINX_BUILD_ASSETS_DIR}/x264"
  cd ${NGINX_BUILD_ASSETS_DIR}/x264
  ./configure \
    --prefix=/usr \
    --enable-shared \
    --disable-opencl
  make -j$(nproc)
  make install
  make DESTDIR=${NGINX_BUILD_ROOT_DIR} install

  download_and_extract "https://libav.org/releases/libav-${LIBAV_VERSION}.tar.gz" "${NGINX_BUILD_ASSETS_DIR}/libav"
  cd ${NGINX_BUILD_ASSETS_DIR}/libav
  ./configure \
    --prefix=/usr \
    --disable-debug \
    --disable-static \
    --enable-shared \
    --enable-nonfree \
    --enable-gpl \
    --enable-libx264 \
    --enable-libfdk-aac
  make -j$(nproc)
  make DESTDIR=${NGINX_BUILD_ROOT_DIR} install

  download_and_extract "https://github.com/arut/nginx-rtmp-module/archive/v${RTMP_VERSION}.tar.gz" ${NGINX_BUILD_ASSETS_DIR}/nginx-rtmp-module
  EXTRA_ARGS+=" --add-module=${NGINX_BUILD_ASSETS_DIR}/nginx-rtmp-module"
}

${WITH_PAGESPEED} && {
  download_and_extract "https://github.com/apache/incubator-pagespeed-ngx/archive/v${NPS_VERSION}-beta.tar.gz" ${NGINX_BUILD_ASSETS_DIR}/ngx_pagespeed
  download_and_extract "https://dl.google.com/dl/page-speed/psol/${NPS_VERSION}.tar.gz" ${NGINX_BUILD_ASSETS_DIR}/ngx_pagespeed/psol
  EXTRA_ARGS+=" --add-module=${NGINX_BUILD_ASSETS_DIR}/ngx_pagespeed"
}

download_and_extract "http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" ${NGINX_BUILD_ASSETS_DIR}/nginx
cd ${NGINX_BUILD_ASSETS_DIR}/nginx
install_packages libpcre++-dev libssl-dev zlib1g-dev libxslt1-dev libgd-dev libgeoip-dev
./configure \
  --prefix=/usr/share/nginx \
  --sbin-path=/usr/sbin/nginx \
  --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log \
  --pid-path=/run/nginx.pid \
  --lock-path=/var/lock/nginx.lock \
  --with-threads \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_realip_module \
  --with-http_addition_module \
  --with-http_xslt_module \
  --with-http_image_filter_module \
  --with-http_sub_module \
  --with-http_dav_module \
  --with-http_gunzip_module \
  --with-http_gzip_static_module \
  --with-http_auth_request_module \
  --with-http_stub_status_module \
  --with-http_geoip_module \
  --http-log-path=/var/log/nginx/access.log \
  --http-client-body-temp-path=/var/lib/nginx/body \
  --http-proxy-temp-path=/var/lib/nginx/proxy \
  --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
  --http-uwsgi-temp-path=/var/lib/nginx/uwsgi \
  --http-scgi-temp-path=/var/lib/nginx/scgi \
  --with-mail \
  --with-mail_ssl_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-pcre-jit \
  --with-cc-opt='-O2 -fstack-protector-strong -Wformat -Werror=format-security -fPIC -D_FORTIFY_SOURCE=2' \
  --with-ld-opt='-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -fPIC' \
  ${EXTRA_ARGS}

make -j$(nproc)
make DESTDIR=${NGINX_BUILD_ROOT_DIR} install

# copy rtmp stats template
${WITH_RTMP} && {
  cp ${NGINX_BUILD_ASSETS_DIR}/nginx-rtmp-module/stat.xsl ${NGINX_BUILD_ROOT_DIR}/usr/share/nginx/html/
}

# create default configuration
mkdir -p ${NGINX_BUILD_ROOT_DIR}/etc/nginx/sites-enabled
cat > ${NGINX_BUILD_ROOT_DIR}/etc/nginx/sites-enabled/default <<EOF
server {
  listen 80 default_server;
  listen [::]:80 default_server ipv6only=on;
  server_name localhost;

  root /usr/share/nginx/html;
  index index.html index.htm;

  location / {
    try_files \$uri \$uri/ =404;
  }

  location /stat {
    rtmp_stat all;
    rtmp_stat_stylesheet stat.xsl;
  }

  location /stat.xsl {
    root html;
  }

  location /control {
    rtmp_control all;
  }

  error_page  500 502 503 504 /50x.html;
    location = /50x.html {
    root html;
  }
}
EOF

strip_debug "${NGINX_BUILD_ROOT_DIR}/usr/bin/" "*"
strip_debug "${NGINX_BUILD_ROOT_DIR}/usr/sbin/" "*"
strip_debug "${NGINX_BUILD_ROOT_DIR}/usr/lib/" "*.so"
strip_debug "${NGINX_BUILD_ROOT_DIR}/usr/lib/" "*.so.*"

rm -rf ${NGINX_BUILD_ROOT_DIR}/usr/share/man
rm -rf ${NGINX_BUILD_ROOT_DIR}/usr/share/include
rm -rf ${NGINX_BUILD_ROOT_DIR}/usr/lib/pkgconfig
