# The pinned OpenTripPlanner image plus the tools build.sh needs, so the whole build runs in one container
# (OTP_MODE=direct) where Docker is not available. Build it from the repository root with OTP_IMAGE taken from
# build.sh, as cloudrun/cloudbuild.yaml does.
ARG OTP_IMAGE
FROM ${OTP_IMAGE}
ARG OTP_IMAGE
ARG RECIPE_COMMIT=

USER root
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends osmium-tool python3 curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --chown=1000:1000 build.sh build-config.json cloudrun/run.sh /recipe/
# The manifest names OTP_IMAGE from build.sh as the image the graph was built with: it must be this image's base.
RUN test "$(sed -n 's/^OTP_IMAGE=//p' /recipe/build.sh)" = "$OTP_IMAGE" && chown 1000:1000 /recipe

ENV OTP_MODE=direct RECIPE_COMMIT=${RECIPE_COMMIT}
USER 1000
ENTRYPOINT ["/recipe/run.sh"]
