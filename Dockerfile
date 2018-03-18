FROM ruby:2.5.0-stretch
WORKDIR /app
RUN apt update && apt install --assume-yes locales
RUN locale-gen ja_JP.UTF-8
ENV LANG ja_JP.UTF-8
ENV LC_CTYPE ja_JP.UTF-8
RUN localedef -f UTF-8 -i ja_JP ja_JP.utf8
COPY Gemfile Gemfile.lock /app/
RUN bundle install
CMD /bin/bash
