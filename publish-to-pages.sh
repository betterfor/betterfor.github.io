#!/bin/bash
set -ev

# get clone master
git clone https://${Github_Ref} ./blog

cd ./blog && git checkout hugo
# generate public file
../hugo
cd ./public 

# add git config
git config user.name "betterfor"
git config user.email "1697606384@qq.com"

git add .
git commit -m "Travis CI Auto Builder at `date +"%Y-%m-%d %H:%M"`"

# push to master
git push --force --quiet "https://${GITHUB_TOKEN}@${Github_Ref}" master:master