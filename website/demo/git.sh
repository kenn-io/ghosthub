# shellcheck shell=bash
# Keep screenshot fixtures reproducible across ordinary developer Git setups.
# Local tools and configuration are trusted by the product threat model, but
# aliases, URL rewrites, templates, and hooks must not change captured content.
demo_git() {
  env \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_CEILING_DIRECTORIES \
    -u GIT_COMMON_DIR \
    -u GIT_CONFIG \
    -u GIT_CONFIG_PARAMETERS \
    -u GIT_CONFIG_SYSTEM \
    -u GIT_DIR \
    -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_WORK_TREE \
    GIT_ALLOW_PROTOCOL=https \
    GIT_CONFIG_COUNT=0 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_PROTOCOL_FROM_USER=0 \
    GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git \
      -c core.hooksPath=/dev/null \
      -c init.templateDir= \
      "$@"
}
