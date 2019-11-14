#!/bin/bash
set -ev

# get clone master
git clone https://${GITHUB_REF} ./blog

cd ./blog && git checkout hugo
# generate public file
../hugo
cd ./public 

# add git config
git config user.name "betterfor"
git config user.email "1697606384@qq.com"

# delete other files
rm -rf archetypes content data layouts resources static themes .travis.yml config.toml publish-to-pages.sh
mv ./public/* ./
rm -rf ./public


git add .
git commit -m "Travis CI Auto Builder at `date +"%Y-%m-%d %H:%M"`"

# push to master
git push --force --quiet "https://${GITHUB_TOKEN}@${GITHUB_REF}" master:master