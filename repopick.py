#!/usr/bin/env python

import sys
import json
import os
import subprocess
import re

try:
  # For python3
  import urllib.request
except ImportError:
  # For python2
  import imp
  import urllib2
  urllib = imp.new_module('urllib')
  urllib.request = urllib2

for change in sys.argv[1:]:
    print(change)
    f = urllib.request.urlopen('http://review.android-legacy.com/query?q=change:%s' % change)
    d = f.read().decode("utf-8")
    # gerrit doesnt actually return json. returns two json blobs, separate lines. bizarre.
    d = d.split('\n')[0]
    data = json.loads(d)
    project = data['project']
    plist = subprocess.Popen([os.environ['HOME']+"/bin/repo","list"], stdout=subprocess.PIPE)
    out, err = plist.communicate()
    if (err is None):
        lines = [re.split('\s*:\s*', line.strip().decode()) for line in out.split('\n') if line.strip()]
        for item in lines:
            if item[1] == project:
                project = item[0]
                break

    print(project)
    number = data['number']

    f = urllib.request.urlopen("http://review.android-legacy.com/changes/%s/revisions/current/review" % number)
    d = f.read().decode("utf-8")
    d = '\n'.join(d.split('\n')[1:])
    data = json.loads(d)

    current_revision = data['current_revision']
    patchset = 0
    ref = ""

    for i in data['revisions']:
        if i == current_revision:
            if 'anonymous http' in data['revisions'][i]['fetch']:
                ref = data['revisions'][i]['fetch']['anonymous http']['ref']
            else:
                ref = data['revisions'][i]['fetch']['http']['ref']
            patchset = data['revisions'][i]['_number']
            break

    print("Patch set: %i" % patchset)
    print("Ref: %s" % ref)

    if not os.path.isdir(project):
        sys.stderr.write('no project directory: %s' % project)
        sys.exit(1)

    os.system('cd %s ; git fetch http://review.android-legacy.com/%s %s' % (project, data['project'], ref))
    os.system('cd %s ; git merge FETCH_HEAD' % project)
