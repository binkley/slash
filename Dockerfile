FROM alpine:latest

# Install bash, ncurses (for tput), and coreutils (for stty/xargs)
RUN apk add --no-cache bash ncurses coreutils

# Create a working directory
WORKDIR /app

# Copy the game engine, configuration file, and test suite
COPY game.sh .
COPY game.cfg .
COPY test.sh .

# Ensure scripts have correct permissions and verify test suite during build
RUN chmod +x game.sh test.sh && ./test.sh

# Set the environment to support 256 colors
ENV TERM=xterm-256color

# Explicitly invoke bash so we can pass flags via command line
ENTRYPOINT ["/bin/bash", "game.sh"]