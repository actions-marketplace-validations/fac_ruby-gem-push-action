#!/usr/bin/env bash
set -e -o pipefail

exec 19> >( sed -e's/^/::debug::/g' )
BASH_XTRACEFD=19
set -x

KEY=""
PRE_RELEASE=false
TAG_RELEASE=false

usage() {
  echo "Usage: $0 [-k KEY] [-p] GEMFILE"
  echo
  echo Options:
  echo "  GEMFILE  The pre-built .gem pkg you want to push"
  echo "  -k KEY   Set the gem host credentials key name. Default: '$KEY'"
  echo "  -p       Do a pre-release, ignore otherwise. Default: $PRE_RELEASE"
  echo "  -t       After pushing a new version, git tag the current ref. Default: $TAG_RELEASE"
  echo "  -h       Show this help"
  exit 0
}

while getopts ":hk:pt" opt; do
  case ${opt} in
    h ) usage
      ;;
    k ) KEY=$OPTARG
      ;;
    p ) PRE_RELEASE=true
      ;;
    t ) TAG_RELEASE=true
      ;;
    \? ) usage
      ;;
  esac
done
shift $((OPTIND -1))

GEM_FILE="$1"

# By default read the gem host from the gemspec, if they dont match the push
# will fail! Allow override if GEM_HOST is already exported.
push_host="$(parse-gemspec --push-host)"
GEM_HOST="${GEM_HOST:-$push_host}"

if [ -z "$GEM_HOST" ]
then
  echo "::error::Push host is missing! Set \`spec.metadata['allowed_push_host']\` in your gemspec"
  exit 1
fi

# test GEM_HOST, gem silently fails with no error if the GEM_HOST redirects
# see https://github.com/rubygems/rubygems/issues/4458
test_response_code=$(curl --silent --output /dev/null --write-out "%{http_code}" --request POST "$GEM_HOST/api/v1/gems")
if [[ $test_response_code != 401 ]] # expecting an 'authentication required' response
then
  echo "::error::Push host looks malformed! Got response of $test_response_code when requesting $GEM_HOST/api/vi/gems" >&2
  echo "::error::Check for HTTPS scheme & no trailing slashes on your allowed push host ($push_host)" >&2
  exit 1
fi

if parse-gemspec --is-pre-release; then
  if [[ $PRE_RELEASE != true ]]; then
    echo "Ignoring pre-release. To release, pass pre-release: true as an input"
    exit 0
  fi
else # normal release
  if [[ $PRE_RELEASE == true ]]; then
    echo "Ignoring release. To release, pass pre-release: false as an input"
    exit 0
  fi
fi

# Capture as we can't tell why gem push failed from the exit code and it logs
# everything to stdout, so need to grep the output. Gem existing is ok, other
# errors not. Avoids playing games setting up auth differently for gem query.
if ! gem push --key="$KEY" --host "$GEM_HOST" "$GEM_FILE" >push.out; then
    gemerr=$?
    sed 's/^Error:/::error::/' push.out
    if grep -q "has already been pushed" push.out; then
        exit 0
    fi
    exit $gemerr
fi

echo "pushed-version=$(parse-gemspec --version)" >> "$GITHUB_OUTPUT"

if [[ $TAG_RELEASE == true ]]; then
    tagname="v$( parse-gemspec --version )"
    git config user.name "$(git log -1 --pretty=format:%an)"
    git config user.email "$(git log -1 --pretty=format:%ae)"
    git tag -a -m "Gem release $tagname" "$tagname"
    git push origin "$tagname"
fi

exit 0
