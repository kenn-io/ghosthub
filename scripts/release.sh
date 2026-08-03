#!/bin/bash
set -euo pipefail

RELEASE_VERSION_FILE="${RELEASE_VERSION_FILE:-RELEASE_VERSION}"
VERSION="$(tr -d '[:space:]' < "$RELEASE_VERSION_FILE")"
TAG_BODY="${1:-}"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: $RELEASE_VERSION_FILE must contain a version in X.Y.Z format."
  exit 1
fi

if ! git diff-index --quiet HEAD --; then
  echo "Error: You have uncommitted changes. Commit or stash them before tagging a release."
  exit 1
fi

TAG="v$VERSION"
RELEASE_REPO="kenn-io/ghosthub"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: Tag $TAG already exists."
  exit 1
fi

TAG_MESSAGE="Release $VERSION"
if [[ -n "$TAG_BODY" ]]; then
  TAG_MESSAGE="$TAG_MESSAGE

$TAG_BODY"
fi

git tag -a "$TAG" -m "$TAG_MESSAGE"
git push origin "$TAG"

echo ""
echo "Pushed tag $TAG."
echo "GitHub Actions will build and publish the signed notarized DMG release to $RELEASE_REPO."
echo "Release URL: https://github.com/$RELEASE_REPO/releases/tag/$TAG"
