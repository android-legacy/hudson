import sys
import urllib
import urllib2
import json
import os
import subprocess
import re

for change in sys.argv[1:]:
    print change
    f = urllib2.urlopen('http://review.androidarmv6.org/query?q=change:%s' % change)
    d = f.read()
    # gerrit doesnt actually return json. returns two json blobs, separate lines. bizarre.
    d = d.split('\n')[0]
    data = json.loads(d)
    project = data['project']

    plist = subprocess.Popen([os.environ['HOME']+"/bin/repo","list"], stdout=subprocess.PIPE)
    out, err = plist.communicate()
    if (err is None):
        data = [re.split('\s*:\s*', line.strip()) for line in out.split('\n') if line.strip()]
        for item in data:
            if item[1] == project:
                project = item[0]
                break

    if not os.path.isdir(project):
        sys.stderr.write('no project directory: %s' % project)
        sys.exit(1)

    retval = os.system('cd %s ; xmllint --noout `git show FETCH_HEAD | grep "^+++ b"  | sed -e \'s/^+++ b\///g\' | egrep "res/.*xml$"`' % (project))
    sys.exit(retval!=0)

