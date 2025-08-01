# Set variables reused in Dockerfile
ARG PYTHON_IMAGE_VERSION=3.13.5-slim-bookworm

# First things first, we build an image which is where we're going to compile
# our static assets with. We use this stage in development.
FROM node:24.4.1-bookworm AS static-deps

WORKDIR /opt/warehouse/src/

# However, we do want to trigger a reinstall of our node.js dependencies anytime
# our package.json changes, so we'll ensure that we're copying that into our
# static container prior to actually installing the npm dependencies.
COPY package.json package-lock.json babel.config.js /opt/warehouse/src/

# Installing npm dependencies is done as a distinct step and *prior* to copying
# over our static files so that, you guessed it, we don't invalidate the cache
# of installed dependencies just because files have been modified.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm ci




# This is our actual build stage, where we'll compile our static assets.
FROM static-deps AS static

# Actually copy over our static files, we only copy over the static files to
# save a small amount of space in our image and because we don't need them. We
# copy `webpack.config.js` last even though it's least likely to change, because
# it's very small so copying it needlessly isn't a big deal but it will save a
# small amount of copying when only `webpack.config.js` is modified.
COPY warehouse/static/ /opt/warehouse/src/warehouse/static/
COPY warehouse/admin/static/ /opt/warehouse/src/warehouse/admin/static/
COPY warehouse/locale/ /opt/warehouse/src/warehouse/locale/
COPY webpack.config.js /opt/warehouse/src/
COPY webpack.plugin.localize.js /opt/warehouse/src/

RUN NODE_ENV=production npm run build




# We'll build a light-weight layer along the way with just docs stuff
FROM python:${PYTHON_IMAGE_VERSION} AS docs

# By default, Docker has special steps to avoid keeping APT caches in the layers, which
# is good, but in our case, we're going to mount a special cache volume (kept between
# builds), so we WANT the cache to persist.
RUN set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache;

# Install System level build requirements, this is done before everything else
# because these are rarely ever going to change.
# Usages:
#  - build-essential: make
#  - git: mkdocs plugin uses this for created/updated
#  - libcairo2: mkdocs uses cairosvg
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -x \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
       build-essential \
       git \
       libcairo2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# We create an /opt directory with a virtual environment in it to store our
# application in.
RUN set -x \
    && python3 -m venv /opt/warehouse

# Now that we've created our virtual environment, we'll go ahead and update
# our $PATH to refer to it first.
ENV PATH="/opt/warehouse/bin:${PATH}"

# Next, we want to update pip inside of this virtual
# environment to ensure that we have the latest version.
# Pinned due to https://github.com/jazzband/pip-tools/issues/2176
RUN pip --no-cache-dir --disable-pip-version-check install --upgrade pip==25.0.1

# We copy this into the docker container prior to copying in the rest of our
# application so that we can skip installing requirements if the only thing
# that has changed is the Warehouse code itself.
COPY requirements /tmp/requirements

# Install the Python level Warehouse requirements, this is done after copying
# the requirements but prior to copying Warehouse itself into the container so
# that code changes don't require triggering an entire install of all of
# Warehouse's dependencies.
RUN --mount=type=cache,target=/root/.cache/pip \
    set -x \
    && pip --disable-pip-version-check \
            install --no-deps --only-binary :all: \
            -r /tmp/requirements/docs-dev.txt \
            -r /tmp/requirements/docs-user.txt \
            -r /tmp/requirements/docs-blog.txt \
    && pip check \
    && find /opt/warehouse -name '*.pyc' -delete

WORKDIR /opt/warehouse/src/

# We'll make the docs container run as a non-root user, ensure that the built
# documentation belongs to the same user on the host machine.
ARG USER_ID
ARG GROUP_ID
RUN groupadd -o -g $GROUP_ID -r docs
RUN useradd -o -m -u $USER_ID -g $GROUP_ID docs
RUN chown docs /opt/warehouse/src
USER docs




# Now we're going to build our actual application, but not the actual production
# image that it gets deployed into.
FROM python:${PYTHON_IMAGE_VERSION} AS build

# Define whether we're building a production or a development image. This will
# generally be used to control whether or not we install our development and
# test dependencies.
ARG DEVEL=no

# Define whether we're building a CI image. This will include all the docs stuff
# as well for the matrix!
ARG CI=no

# To enable Ipython in the development environment set to yes (for using ipython
# as the warehouse shell interpreter,
# i.e. 'docker compose run --rm web python -m warehouse shell --type=ipython')
ARG IPYTHON=no

# We create an /opt directory with a virtual environment in it to store our
# application in.
RUN set -x \
    && python3 -m venv /opt/warehouse

# Now that we've created our virtual environment, we'll go ahead and update
# our $PATH to refer to it first.
ENV PATH="/opt/warehouse/bin:${PATH}"

# Next, we want to update pip inside of this virtual
# environment to ensure that we have the latest version.
# Pinned due to https://github.com/jazzband/pip-tools/issues/2176
RUN pip --no-cache-dir --disable-pip-version-check install --upgrade pip==25.0.1

# We copy this into the docker container prior to copying in the rest of our
# application so that we can skip installing requirements if the only thing
# that has changed is the Warehouse code itself.
COPY requirements /tmp/requirements

# Install our development dependencies if we're building a development install
# otherwise this will do nothing.
RUN --mount=type=cache,target=/root/.cache/pip \
    set -x \
    && if [ "$DEVEL" = "yes" ]; then pip --disable-pip-version-check install -r /tmp/requirements/dev.txt; fi

RUN --mount=type=cache,target=/root/.cache/pip \
    set -x \
    && if [ "$DEVEL" = "yes" ] && [ "$IPYTHON" = "yes" ]; then pip --disable-pip-version-check install -r /tmp/requirements/ipython.txt; fi

# Install the Python level Warehouse requirements, this is done after copying
# the requirements but prior to copying Warehouse itself into the container so
# that code changes don't require triggering an entire install of all of
# Warehouse's dependencies.
RUN --mount=type=cache,target=/root/.cache/pip \
    set -x \
    && pip --disable-pip-version-check \
            install --no-deps --only-binary :all: \
                    -r /tmp/requirements/deploy.txt \
                    -r /tmp/requirements/main.txt \
                    $(if [ "$DEVEL" = "yes" ]; then echo '-r /tmp/requirements/tests.txt -r /tmp/requirements/lint.txt'; fi) \
                    $(if [ "$CI" = "yes" ]; then echo '-r /tmp/requirements/docs-dev.txt -r /tmp/requirements/docs-user.txt -r /tmp/requirements/docs-blog.txt'; fi ) \
    && pip check \
    && find /opt/warehouse -name '*.pyc' -delete




# Now we're going to build our actual application image, which will eventually
# pull in the static files that were built above.
FROM python:${PYTHON_IMAGE_VERSION}

# Setup some basic environment variables that are ~never going to change.
ENV PYTHONUNBUFFERED 1
ENV PYTHONPATH /opt/warehouse/src/
ENV PATH="/opt/warehouse/bin:${PATH}"

WORKDIR /opt/warehouse/src/

# Define whether we're building a production or a development image. This will
# generally be used to control whether or not we install our development and
# test dependencies.
ARG DEVEL=no

# Define whether we're building a CI image. This will include all the docs stuff
# as well for the matrix!
ARG CI=no

# By default, Docker has special steps to avoid keeping APT caches in the layers, which
# is good, but in our case, we're going to mount a special cache volume (kept between
# builds), so we WANT the cache to persist.
RUN set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache;

# Install System level Warehouse requirements, this is done before everything
# else because these are rarely ever going to change.
# Usages:
#  - build-essential: make
#  - postgresql-client: make initdb and friends
#  - oathtool: make totp
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -x \
    && if [ "$DEVEL" = "yes" ]; then \
        apt-get update \
        && apt-get install --no-install-recommends -y \
           build-essential \
           postgresql-client \
           oathtool \
        && apt-get clean \
        && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*; \
    fi

# Copy the directory into the container, this is done last so that changes to
# Warehouse itself require the least amount of layers being invalidated from
# the cache. This is most important in development, but it also useful for
# deploying new code changes.
COPY --from=static /opt/warehouse/src/warehouse/static/dist/ /opt/warehouse/src/warehouse/static/dist/
COPY --from=static /opt/warehouse/src/warehouse/admin/static/dist/ /opt/warehouse/src/warehouse/admin/static/dist/
COPY --from=build /opt/warehouse/ /opt/warehouse/
COPY . /opt/warehouse/src/

# Pre-cache TLD list
RUN tldextract --update
# Load our module to pre-compile as much bytecode as we can easily.
# Saves time collectively on container boot!
RUN python -m warehouse db -h
