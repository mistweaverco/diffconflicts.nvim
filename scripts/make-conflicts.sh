#!/usr/bin/env bash

git init tmp/testrepo
cd tmp/testrepo || exit 1

cat << EOF > main.js
console.log('Hello, world!');
console.log('This is a test.');
console.log('Goodbye, world!');
EOF

git add main.js
git commit -m 'Commit One'

git branch branchA

cat << EOF > main.js
console.log('Hello, everyone!');
console.log('This is a test.');
console.warn('Goodbye, world.');
EOF

git add main.js
git commit -m 'Commit Two'

git checkout branchA

cat << EOF > main.js
console.log('Hello, world!');
console.log('This is a test!!!');
console.info('Farewell, world!');
EOF

git add main.js
git commit -m 'Commit Three'

git checkout main
git merge branchA
