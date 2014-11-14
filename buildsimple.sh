#!/usr/bin/env bash

if [[ "$ROM_BUILDTYPE" == "RELEASE" ]]
then
  export USE_CCACHE=0
else
  export USE_CCACHE=1
  export CCACHE_NLEVELS=4
fi

REPO=$(which repo)
if [ -z "$REPO" ]
then
  mkdir -p ~/bin
  curl https://dl-ssl.google.com/dl/googlesource/git-repo/repo > ~/bin/repo
  chmod a+x ~/bin/repo
fi

if [ -z "$BUILD_USER_ID" ]
then
  export BUILD_USER_ID=$(whoami)
fi

git config --global user.name erikcas
git config --global user.email erikcas1972@gmail.com

JENKINS_BUILD_DIR=$REPO_BRANCH

mkdir -p $JENKINS_BUILD_DIR
cd $JENKINS_BUILD_DIR

# always force a fresh repo init since we can build off different branches
# and the "default" upstream branch can get stuck on whatever was init first.
if [ -z "$CORE_BRANCH" ]
then
  CORE_BRANCH=$REPO_BRANCH
fi

if [ ! -z "$RELEASE_MANIFEST" ]
then
  MANIFEST="-m $RELEASE_MANIFEST"
else
  RELEASE_MANIFEST=""
  MANIFEST=""
fi

# remove manifests
rm -rf .repo/manifests*
rm -f .repo/local_manifests/dyn-*.xml
rm -f .repo/local_manifest.xml
repo init repo init -u https://android.googlesource.com/platform/manifest -b $CORE_BRANCH $MANIFEST

if [ $USE_CCACHE -eq 1 ]
then
  # make sure ccache is in PATH
  export PATH="$PATH:/opt/local/bin/:$PWD/prebuilts/misc/$(uname|awk '{print tolower($0)}')-x86/ccache"
  export CCACHE_DIR=~/ccache-jenkins/$JOB_NAME/$REPO_BRANCH
  mkdir -p $CCACHE_DIR
fi

mkdir -p .repo/local_manifests
rm -f .repo/local_manifest.xml
rm -f .repo/local_manifests/*
cd .repo/local_manifests/
wget http://git.cas-online.nl/local_manifest/plain/local_manifest.xml
cd ../../
echo Core Manifest:
cat .repo/manifest.xml
echo Local Manifest
cat .repo/local_manifests/local_manifest.xml

echo Syncing...

repo sync -j4

# SUCCESS
echo Sync complete.

if [ -f .last_branch ]
then
  LAST_BRANCH=$(cat .last_branch)
else
  echo "Last build branch is unknown, assume clean build"
  LAST_BRANCH=$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST
fi

if [ "$LAST_BRANCH" != "$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST" ]
then
  echo "Branch has changed since the last build happened here. Forcing cleanup."
  CLEAN="true"
fi

. build/envsetup.sh
lunch $LUNCH

# save manifest used for build (saving revisions as current HEAD)

# include only the auto-generated locals
TEMPSTASH=$(mktemp -d)
mv .repo/local_manifests/* $TEMPSTASH
mv $TEMPSTASH/roomservice.xml .repo/local_manifests/

# save it
repo manifest -o $WORKSPACE/archive/manifest.xml -r

# restore all local manifests
mv $TEMPSTASH/* .repo/local_manifests/ 2>/dev/null
rmdir $TEMPSTASH

rm -f $OUT/*.zip*

UNAME=$(uname)

if [ ! -z "$CM_EXTRAVERSION" ]
then
  export CM_EXPERIMENTAL=true
fi

if [ $USE_CCACHE -eq 1 ]
then
  if [ ! "$(ccache -s|grep -E 'max cache size'|awk '{print $4}')" = "64.0" ]
  then
    ccache -M 64G
  fi
  echo "============================================"
  ccache -s
  echo "============================================"
fi


rm -f $WORKSPACE/changecount
WORKSPACE=$WORKSPACE LUNCH=$LUNCH bash $WORKSPACE/hudson/changes/buildlog.sh 2>&1
if [ -f $WORKSPACE/changecount ]
then
  CHANGE_COUNT=$(cat $WORKSPACE/changecount)
  rm -f $WORKSPACE/changecount
  if [ $CHANGE_COUNT -eq "0" ]
  then
    echo "Zero changes since last build, aborting"
    exit 1
  fi
fi

LAST_CLEAN=0
if [ -f .clean ]
then
  LAST_CLEAN=$(date -r .clean +%s)
fi
TIME_SINCE_LAST_CLEAN=$(expr $(date +%s) - $LAST_CLEAN)
# convert this to hours
TIME_SINCE_LAST_CLEAN=$(expr $TIME_SINCE_LAST_CLEAN / 60 / 60)
if [ $TIME_SINCE_LAST_CLEAN -gt "24" -o $CLEAN = "true" ]
then
  echo "Cleaning!"
  touch .clean
  make clobber
else
  echo "Skipping clean: $TIME_SINCE_LAST_CLEAN hours since last clean."
fi

echo "$REPO_BRANCH-$CORE_BRANCH$RELEASE_MANIFEST" > .last_branch

# envsetup.sh:mka = schedtool -B -n 1 -e ionice -n 1 make -j$(cat /proc/cpuinfo | grep "^processor" | wc -l) "$@"
# Don't add -jXX. mka adds it automatically...
cd build

git cherry-pick 612e2cd0e8c79bc6ab46d13cd96c01d1be382139

cd ..

cd hardware/qcom/bt

git cherry-pick 5a6037f1c8b5ff0cf263c9e63777444ba239a056

cd ../../../

cd hardware/qcom/audio

git cherry-pick 00f6869a0981b570f90dbf39981734f36eafdfa9
git cherry-pick 20bcfa8b451941843e8eabb5308f1f04f07d347a

cd ../../../

cd hardware/qcom/display

git cherry-pick d5ae1812a9509d8849f4494fcf17f68bf33f533c

git cherry-pick 5898f2e789800fb196ce94532eef033e7d7e60b3

cd ../../../

make -j16 otapackage

if [ $USE_CCACHE -eq 1 ]
then
  echo "============================================"
  ccache -V
  echo "============================================"
  ccache -s
  echo "============================================"
fi

# ClamAV virus scan
if [ "$VIRUS_SCAN" = "true" ]
then
  CLAMAV_SIGNATURE=`clamdscan --version`
  echo "Scanning for viruses with $CLAMAV_SIGNATURE..."
  clamdscan --infected --multiscan --fdpass $OUT > $WORKSPACE/archive/virusreport.txt
  SCAN_RESULT=$?
  if [ $SCAN_RESULT -eq 0 ]
  then
    echo "No virus detected."
  elif [ $SCAN_RESULT -eq 1 ]
  then
    echo Virus FOUND. Removing $OUT...
    make clobber >/dev/null
    rm -fr $OUT
    if [ ! -z "$GERRIT_CHANGE_NUMBER" ] && [ ! -z "$GERRIT_PATCHSET_NUMBER" ] && [ ! -z "$BUILD_URL" ]
    then
      ssh -p 29418 $BUILD_USER_ID@review.cas-online.nl gerrit review $GERRIT_CHANGE_NUMBER,$GERRIT_PATCHSET_NUMBER --code-review -1 --message "'$BUILD_URL : VIRUS FOUND'"
    fi
    exit 1
  fi
fi

# /archive
for f in $(ls $OUT/*.zip*)
do
  ln $f $WORKSPACE/archive/$(basename $f)
done
if [ -f $OUT/utilties/update.zip ]
then
  cp $OUT/utilties/update.zip $WORKSPACE/archive/recovery.zip
fi
if [ -f $OUT/recovery.img ]
then
  cp $OUT/recovery.img $WORKSPACE/archive
fi

# archive the build.prop as well
ZIP=$(ls $WORKSPACE/archive/*.zip)
unzip -p $ZIP system/build.prop > $WORKSPACE/archive/build.prop

# CORE: save manifest used for build (saving revisions as current HEAD)
rm -f .repo/local_manifests/roomservice.xml

# Stash away other possible manifests
TEMPSTASH=$(mktemp -d)
mv .repo/local_manifests $TEMPSTASH

repo manifest -o $WORKSPACE/archive/core.xml -r

mv $TEMPSTASH/local_manifests .repo
rmdir $TEMPSTASH

# chmod the files in case UMASK blocks permissions
chmod -R ugo+r $WORKSPACE/archive

CMCP=$(which cmcp)
if [ ! -z "$CMCP" -a ! -z "$CM_RELEASE" ]
then
  MODVERSION=$(cat $WORKSPACE/archive/build.prop | grep ro.modversion | cut -d = -f 2)
  if [ -z "$MODVERSION" ]
  then
    MODVERSION=$(cat $WORKSPACE/archive/build.prop | grep ro.aosp.version | cut -d = -f 2)
  fi
  if [ -z "$MODVERSION" ]
  then
    echo "Unable to detect ro.modversion or ro.aosp.version."
    exit 1
  fi
  echo Archiving release to S3.
  for f in $(ls $WORKSPACE/archive)
  do
    cmcp $WORKSPACE/archive/$f release/$MODVERSION/$f > /dev/null 2> /dev/null
  done
fi
