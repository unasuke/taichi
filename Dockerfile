FROM ruby:2.5.0-stretch
WORKDIR /app
COPY Gemfile Gemfile.lock /app/
RUN bundle install
CMD bundle exec pry
