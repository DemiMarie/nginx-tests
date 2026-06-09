#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for HTTP methods.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

plan(skip_all => 'broken');

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http rewrite/)->plan(6)
	->write_file_expand('nginx.conf', <<'EOF')->run();

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            return 200;
        }
    }
}

EOF

###############################################################################

like(http(<<EOF), qr/505 HTTP Version Not Supported/, 'HTTP 0.9');
GET / HTTP/0.9
Host: localhost

EOF

like(http(<<EOF), qr/200 OK/, 'HTTP 1.0');
GET / HTTP/1.0
Host: localhost

EOF

like(http(<<EOF), qr/400 Bad/, 'HTTP 1.00');
GET / HTTP/1.00
Host: localhost

EOF


like(http(<<EOF), qr/505 HTTP Version Not Supported/, 'HTTP 1.11');
GET / HTTP/1.11
Host: localhost

EOF


like(http(<<EOF), qr/200 OK/, 'HTTP 1.1');
GET / HTTP/1.1\r
Host: localhost\r
Connection: close\r
\r
EOF

like(http(<<EOF), qr/505 HTTP Version Not Supported/, 'HTTP 1.2');
GET / HTTP/1.2
Host: localhost

EOF
###############################################################################

