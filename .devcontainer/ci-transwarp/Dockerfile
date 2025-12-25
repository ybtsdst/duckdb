FROM ubuntu:22.04

ARG HTTP_PROXY 
ARG GO_VERSION=1.24.9

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
  PKGS="${PKGS} google-perftools valgrind" && \    
  apt-get install -y ${PKGS} && \    
  locale-gen en_US.UTF-8 && \    
  echo ${TZ} > /etc/timezone && \
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
  dpkg-reconfigure tzdata && \
  apt-get autoclean && apt-get autoremove && \    
  rm -rf /var/lib/apt/lists/*

RUN \
    cp /etc/wgetrc /etc/wgetrc.bak && \
    # proxy for wget
    echo "use_proxy = on" >> /etc/wgetrc && \
    echo "http_proxy = ${HTTP_PROXY}" >> /etc/wgetrc && \
    echo "https_proxy = ${HTTP_PROXY}" >> /etc/wgetrc && \
    # misc
    echo "* soft core unlimited" >>/etc/security/limits.conf && \
    mkdir /coredumps && \
    chmod o+rwx /coredumps

RUN \
  # Install Go
  wget "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz && \
  tar -C /usr/local -xzf /tmp/go.tar.gz && \
  rm -rf /tmp/go.tar.gz

ENV GOPATH=/opt/go
ENV GOPROXY=https://goproxy.cn,direct
ENV GOSUMDB=off
ENV PATH=/usr/local/go/bin:${GOPATH}/bin:${PATH}

ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"

RUN go install github.com/google/pprof@latest

# unset
ENV http_proxy=
ENV https_proxy=
ENV HTTP_PROXY=
ENV HTTPS_PROXY=
ENV ALL_PROXY=

# unset wget proxy
RUN cp /etc/wgetrc.bak /etc/wgetrc && rm -f /etc/wgetrc.bak