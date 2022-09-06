FROM ruby:3.1.1
# argument for build: location of gem file
ARG gemfile
# install gem from local build and optional gems
COPY $gemfile aspera-cli.gem
RUN gem install aspera-cli.gem grpc mimemagic
RUN rm aspera-cli.gem
# add user to run cli
RUN useradd -m -u 1000 -s /bin/bash cliuser
# Ensures that the docker container always start with this user
USER cliuser
# The default dir when starting the docker container. 
WORKDIR /home/cliuser
# this folder can be mounted as volume
RUN mkdir transfer
# install SDK
RUN ascli conf ascp install
# create key files
RUN ascli conf ascp info
CMD ["ascli"]
