FROM ruby:2.5.5-buster

ENV DEBIAN_FRONTEND noninteractive

#########################################
# Mysql server 
# reference: https://github.com/docker-library/mysql/blob/master/5.7/Dockerfile
#########################################
# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mysql && useradd -r -g mysql mysql

RUN apt-get update && apt-get install -y --no-install-recommends gnupg dirmngr && rm -rf /var/lib/apt/lists/*

# add gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION 1.12
RUN set -eux; \
  savedAptMark="$(apt-mark showmanual)"; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates wget; \
  rm -rf /var/lib/apt/lists/*; \
  dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
  wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
  wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
  export GNUPGHOME="$(mktemp -d)"; \
  gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
  gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
  gpgconf --kill all; \
  rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
  apt-mark auto '.*' > /dev/null; \
  [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
  apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
  chmod +x /usr/local/bin/gosu; \
  gosu --version; \
  gosu nobody true

RUN mkdir /docker-entrypoint-initdb.d

RUN apt-get update && apt-get install -y --no-install-recommends \
  # for MYSQL_RANDOM_ROOT_PASSWORD
  pwgen \
  # for mysql_ssl_rsa_setup
  openssl \
  # FATAL ERROR: please install the following Perl modules before executing /usr/local/mysql/scripts/mysql_install_db:
  # File::Basename
  # File::Copy
  # Sys::Hostname
  # Data::Dumper
  perl \
  # install "xz-utils" for .sql.xz docker-entrypoint-initdb.d files
  xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN set -ex; \
  # gpg: key 5072E1F5: public key "MySQL Release Engineering <mysql-build@oss.oracle.com>" imported
  key='A4A9406876FCBD3C456770C88C718D3B5072E1F5'; \
  export GNUPGHOME="$(mktemp -d)"; \
  gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
  gpg --batch --export "$key" > /etc/apt/trusted.gpg.d/mysql.gpg; \
  gpgconf --kill all; \
  rm -rf "$GNUPGHOME"; \
  apt-key list > /dev/null

ENV MYSQL_MAJOR 5.7
ENV MYSQL_VERSION 5.7.30-1debian10

RUN echo "deb http://repo.mysql.com/apt/debian/ buster mysql-${MYSQL_MAJOR}" > /etc/apt/sources.list.d/mysql.list

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN { \
  echo mysql-community-server mysql-community-server/data-dir select ''; \
  echo mysql-community-server mysql-community-server/root-pass password ''; \
  echo mysql-community-server mysql-community-server/re-root-pass password ''; \
  echo mysql-community-server mysql-community-server/remove-test-db select false; \
  } | debconf-set-selections \
  && apt-get update && apt-get install -y mysql-server="${MYSQL_VERSION}" && rm -rf /var/lib/apt/lists/* \
  && rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld \
  && chown -R mysql:mysql /var/lib/mysql /var/run/mysqld \
  # ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
  && chmod 777 /var/run/mysqld \
  # comment out a few problematic configuration values
  && find /etc/mysql/ -name '*.cnf' -print0 \
  | xargs -0 grep -lZE '^(bind-address|log)' \
  | xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/' \
  # don't reverse lookup hostnames, they are usually another container
  && echo '[mysqld]\nskip-host-cache\nskip-name-resolve' > /etc/mysql/conf.d/docker.cnf

VOLUME /var/lib/mysql

RUN apt-get update && \
  apt-get install -y  --no-install-recommends mysql-client libmysqlclient-dev nodejs\
  graphicsmagick poppler-utils poppler-data ghostscript \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app
WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN gem install bundler && bundle install --jobs 20 --retry 5
COPY . ./
RUN rm config/credentials.yml.enc
COPY config/master.key.sample config/master.key
COPY config/credentials.yml.enc.sample config/credentials.yml.enc

COPY docker-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
RUN chmod +x docker-entrypoint.sh
COPY mysql_entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/mysql_entrypoint.sh
RUN ln -s usr/local/bin/entrypoint.sh /entrypoint.sh # backwards compat
ENV MYSQL_ALLOW_EMPTY_PASSWORD true

ENTRYPOINT ["entrypoint.sh"]

EXPOSE 3000
EXPOSE 3306
# Start the main process.
# CMD ["rails", "server", "-b", "0.0.0.0"]