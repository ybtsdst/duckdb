FROM ubuntu:22.04

ARG HTTP_PROXY 

ENV DEBIAN_FRONTEND=noninteractive    
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTP_PROXY}
ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTP_PROXY}
ENV ALL_PROXY=${HTTP_PROXY}
ENV TZ=Asia/Shanghai

RUN \
  sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
  sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
  echo 'Acquire::ForceIPv4 "true";' >> /etc/apt/apt.conf.d/1000-force-ipv4-transport && \    
  echo 'Acquire::Retries "100";' >> /etc/apt/apt.conf.d/80-retries && \
  apt-get update -y && \    
  # basics    
  PKGS="software-properties-common" && \
  apt-get install -y ${PKGS} && \    
  add-apt-repository -y ppa:ubuntu-toolchain-r/ppa && \
  apt-get update -y && \    
  PKGS="vim sudo locales git curl unzip wget zip iputils-ping iproute2 tzdata tree jq" && \    
  PKGS="${PKGS} gdb net-tools telnet linux-tools-common linux-tools-generic" && \    
  apt-get install -y ${PKGS} && \    
  locale-gen en_US.UTF-8 && \    
  echo ${TZ} > /etc/timezone && \
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
  dpkg-reconfigure tzdata && \
  apt-get autoclean && apt-get autoremove && \    
  rm -rf /var/lib/apt/lists/*

RUN \
    # misc
    echo "* soft core unlimited" >>/etc/security/limits.conf && \
    mkdir /coredumps && \
    chmod o+rwx /coredumps

ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"

# unset
ENV http_proxy=
ENV https_proxy=
ENV HTTP_PROXY=
ENV HTTPS_PROXY=
ENV ALL_PROXY=