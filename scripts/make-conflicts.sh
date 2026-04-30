#!/usr/bin/env bash

ALLOWED_VALUES_GIT_OR_JJ=("git" "jj")
ALLOWED_VALUES_CONFLICTING_FILES=("onefile" "twofiles")

GIT_OR_JJ=${1:-"git"}
CONFLICTING_FILES=${2:-"onefile"}

if [[ ! " ${ALLOWED_VALUES_GIT_OR_JJ[*]} " =~ " ${GIT_OR_JJ} " ]]; then
  echo "❌ Invalid value for GIT_OR_JJ: '$GIT_OR_JJ'. Allowed values are: ${ALLOWED_VALUES_GIT_OR_JJ[*]}"
  exit 1
fi

if [[ ! " ${ALLOWED_VALUES_CONFLICTING_FILES[*]} " =~ " ${CONFLICTING_FILES} " ]]; then
  echo "❌ Invalid value for CONFLICTING_FILES: '$CONFLICTING_FILES'. Allowed values are: ${ALLOWED_VALUES_CONFLICTING_FILES[*]}"
  exit 1
fi

if [[ -d tmp/testrepo ]]; then
  echo "🗑️ Removing existing test repository..."
  rm -rf tmp/testrepo
fi

if [ "$GIT_OR_JJ" == "jj" ]; then
  if ! command -v jj &> /dev/null; then
    echo "❌ 'jj' command not found. Please install 'jj' to run this script with jj."
    exit 1
  else
    echo "✅ 'jj' command found. Proceeding with jj setup."
  fi
fi
if [ "$GIT_OR_JJ" == "git" ]; then
  if ! command -v git &> /dev/null; then
    echo "❌ 'git' command not found. Please install 'git' to run this script."
    exit 1
  else
    echo "✅ 'git' command found. Proceeding with git setup."
  fi
fi

echo "🚀 Setting up test repository with conflicting changes..."
git init tmp/testrepo
cd tmp/testrepo || exit 1

cat << EOF > poem.txt
twas bri1lig, and the slithy toves
did gyre and gimble in the wabe
all mimsy were the borogroves
and the m0me raths outgabe.

"Beware the Jabberwock, my son!
The jaws that bite, the claws that catch!
Beware the Jub jub bird, and shun
The frumious bandersnatch!"
EOF

if [[ "$CONFLICTING_FILES" == "twofiles" ]]; then
  cat << EOF > main.js
console.log('Hello, world!');
console.log('This is a test.');
console.log('Goodbye, world!');
EOF
fi

if [[ "$CONFLICTING_FILES" == "onefile" ]]; then
  git add poem.txt
fi
if [[ "$CONFLICTING_FILES" == "twofiles" ]]; then
  git add poem.txt main.js
fi

git commit -m 'Commit One'

git branch branchA

cat << EOF > poem.txt
twas brillig, and the slithy toves
Did gyre and gimble in the wabe:
all mimsy were the borogoves,
And the mome raths outgrabe.

"Beware the Jabberwock, my son!
The jaws that bite, the claws that catch!
Beware the Jubjub bird, and shun
The frumious Bandersnatch!"
EOF

if [[ "$CONFLICTING_FILES" == "twofiles" ]]; then
  cat << EOF > main.js
console.log('Hello, everyone!');
console.log('This is a test.');
console.warn('Goodbye, world.');
EOF
fi

if [[ "$CONFLICTING_FILES" == "onefile" ]]; then
  git add poem.txt
fi
if [[ "$CONFLICTING_FILES" == "twofiles" ]]; then
  git add poem.txt main.js
fi

git commit -m 'Initial Commit'

git checkout branchA

cat << EOF > poem.txt
'Twas brillig, and the slithy toves
Did gyre and gimble in the wabe:
All mimsy were the borogroves
And the mome raths outgabe.

"Beware the Jabberwock, my son!
The jaws that bite, the claws that catch!
Beware the Jub jub bird, and shun
The frumious bandersnatch!"
EOF

if [[ "$CONFLICTING_FILES" == "twofiles" ]]; then
  cat << EOF > main.js
console.log('Hello, world!');
console.log('This is a test!!!');
console.info('Farewell, world!');
EOF
fi

if [[ "$CONFLICTING_FILES" == "onefile" ]]; then
  git commit -m 'Initial Commit'
fi
if [[ "$CONFLICTING_FILES" == "twofiles" ]]; then
  git add poem.txt main.js
fi

git commit -m 'Commit Three'

git checkout main

if [ "$GIT_OR_JJ" == "jj" ]; then
  jj git init --colocate
  jj new main branchA
fi
if [ "$GIT_OR_JJ" == "git" ]; then
  git merge branchA
fi
