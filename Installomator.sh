#!/bin/sh

# Installomator

# Downloads and installs an Applications

# inspired by the download scripts from William Smith and Sander Schram

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

DEBUG=1 # (set to 0 for production, 1 for debugging)
JAMF=0 # if this is set to 1, the argument will be picked up at $4 instead of $1

if [ "$JAMF" -eq 0 ]; then
    identifier=${1:?"no identifier provided"}
else
    identifier=${4:?"argument $4 required"}
fi

# each identifier needs to be listed in the case statement below
# for each identifier these three variables must be set:
#
# - downloadURL: 
#   URL to download the dmg
# 
# - dmgName: (optional)
#   The name of the downloaded dmg
#   When not given the dmgName is derived from the last part of the downloadURL
#
# - appName: (optional)
#   file name of the app bundle in the dmg to verify and copy (include .app)
#   When not given, the App name is derived from the dmgName by removing the extension
#   and adding .app
#
# - expectedTeamID:
#   10-digit developer team ID
#   obtain this by running 
#
#   spctl -a -vv /Applications/BBEdit.app
#
#   the team ID is the ten-digit ID at the end of the line starting with 'origin='

# target directory (remember to _omit_ last / )
targetDir="/Applications"
# this can be overridden below if you want a different location for a specific identifier


# functions to help with getting info

downloadURLFromGit() { # $1 git user name, $2 git repo name
    gitusername=${1?:"no git user name"}
    gitreponame=${2?:"no git repo name"}
    
    downloadURL=$(curl --silent --fail "https://api.github.com/repos/$gitusername/$gitreponame/releases/latest" | awk -F '"' '/browser_download_url/ { print $4 }')
    if [ -z "$downloadURL" ]; then
        echo "could not retrieve download URL for $gitusername/$gitreponame"
        cleanupAndExit 9
    else
        echo "$downloadURL"
        return 0
    fi
}

# add identifiers in this case statement

case $identifier in

    GoogleChrome)
        downloadURL="https://dl.google.com/chrome/mac/stable/GGRO/googlechrome.dmg"
        appName="Google Chrome.app"
        expectedTeamID="EQHXZ8M8AV"
        ;;
    Spotify)
        downloadURL="https://download.scdn.co/Spotify.dmg"
        expectedTeamID="2FNC3A47ZF"
        ;;
    BBEdit)
        downloadURL=$(curl -s https://versioncheck.barebones.com/BBEdit.xml | grep dmg | sort | tail -n1 | cut -d">" -f2 | cut -d"<" -f1)
        expectedTeamID="W52GZAXT98"
        ;;
    Firefox)
        downloadURL="https://download.mozilla.org/?product=firefox-latest&amp;os=osx&amp;lang=en-US"
        dmgName="Firefox.dmg"
        expectedTeamID="43AQ936H96"
        ;;
    WhatsApp)
        downloadURL="https://web.whatsapp.com/desktop/mac/files/WhatsApp.dmg"
        expectedTeamID="57T9237FN3"
        ;;
    brokenDownloadURL)
        downloadURL="https://broken.com/broken.dmg"
        appName="Google Chrome.app"
        expectedTeamID="EQHXZ8M8AV"
        ;;
    brokenAppName)
        downloadURL="https://dl.google.com/chrome/mac/stable/GGRO/googlechrome.dmg"
        appName="broken.app"
        expectedTeamID="EQHXZ8M8AV"
        ;;
    brokenTeamID)
        downloadURL="https://dl.google.com/chrome/mac/stable/GGRO/googlechrome.dmg"
        appName="Google Chrome.app"
        expectedTeamID="broken"
        ;;
    *)
        # unknown identifier
        echo "unknown identifier $identifier"
        exit 1
        ;;
esac

if [ -z "$dmgName" ]; then
    dmgName="${downloadURL##*/}"
fi

if [ -z "$appName" ]; then
    appName="${dmgName%%.*}.app"
fi

cleanupAndExit() { # $1 = exit code
    if [ "$DEBUG" -eq 0 ]; then
        # remove the temporary working directory when done
        echo "Deleting $tmpDir"
        rm -Rf "$tmpDir"
    else
        open "$tmpDir"
    fi
    
    if [ -n "$dmgmount" ]; then
        # unmount disk image
        echo "Unmounting $dmgmount"
        hdiutil detach "$dmgmount"
    fi
    exit "$1"
}

# create temporary working directory
tmpDir=$(mktemp -d )
if [ "$DEBUG" -eq 1 ]; then
    # for debugging use script dir as working directory
    tmpDir=$(dirname "$0")
fi

# change directory to temporary working directory
echo "Changing directory to $tmpDir"
if ! cd "$tmpDir"; then
    echo "error changing directory $tmpDir"
    #rm -Rf "$tmpDir"
    cleanupAndExit 1
fi

# TODO: when user is logged in, and app is running, prompt user to quit app

if [ -f "$dmgName" ] && [ "$DEBUG" -eq 1 ]; then
    echo "$dmgName exists and DEBUG enabled, skipping download"
else
    # download the dmg
    echo "Downloading $downloadURL to $dmgName"
    if ! curl --location --fail --silent "$downloadURL" -o "$dmgName"; then
        echo "error downloading $downloadURL"
        cleanupAndExit 2
    fi
fi

# mount the dmg
echo "Mounting $tmpDir/$dmgName"
# set -o pipefail
if ! dmgmount=$(hdiutil attach "$tmpDir/$dmgName" -nobrowse -readonly | tail -n 1 | cut -c 54- ); then
    echo "Error mounting $tmpDir/$dmgName"
    cleanupAndExit 3
fi
echo "Mounted: $dmgmount"

# check if app exists
if [ ! -e "$dmgmount/$appName" ]; then
    echo "could not find: $dmgmount/$appName"
    cleanupAndExit 8
fi

# verify with spctl
echo "Verifying: $dmgmount/$appName"
if ! teamID=$(spctl -a -vv "$dmgmount/$appName" 2>&1 | awk '/origin=/ {print $NF }' ); then
    echo "Error verifying $dmgmount/$appName"
    cleanupAndExit 4
fi

echo "Team ID: $teamID (expected: $expectedTeamID )"

if [ "($expectedTeamID)" != "$teamID" ]; then
    echo "Team IDs do not match!"
    cleanupAndExit 5
fi

# check for root
if [ "$(whoami)" != "root" ]; then
    # not running as root
    if [ "$DEBUG" -eq 0 ]; then
        echo "not running as root, exiting"
        cleanupAndExit 6
    fi
    
    echo "DEBUG enabled, skipping copy and chown steps"
    cleanupAndExit 0
fi

# remove existing application
if [ -e "$targetDir/$appName" ]; then
    echo "Removing existing $targetDir/$appName"
    rm -Rf "$targetDir/$appName"
fi

# copy app to /Applications
echo "Copy $dmgmount/$appName to $targetDir"
if ! ditto "$dmgmount/$appName" "$targetDir"; then
    echo "Error while copying!"
    cleanupAndExit 7
fi


# set ownership to current user
currentUser=$( echo "show State:/Users/ConsoleUser" | scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }' )
if [ -n "$currentUser" ]; then
    echo "Changing owner to $currentUser"
    chown -R "$currentUser" "$targetDir/$appName" 
else
    echo "No user logged in, not changing user"
fi

# TODO: notify when done

# all done!
cleanupAndExit 0
