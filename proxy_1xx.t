#!/usr/bin/perl

# (C) Nginx, Inc.

# Tests for proxy to ssl backend.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;
use Test::Nginx::HTTP3;
use Data::Dumper;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2 http_v3 proxy/)
	->has_daemon('openssl')->plan(690)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%
    error_log /dev/tty info;

    ssl_certificate_key localhost.key;
    ssl_certificate localhost.crt;

    log_format test $uri:$status:$request_completion;

    server {
        listen       127.0.0.1:%%PORT_8980_UDP%% quic;
        listen       127.0.0.1:8080;
        server_name  localhost;
        http2        on;
        early_hints  1;

        access_log %%TESTDIR%%/test.log test;

        location / {
            proxy_pass http://127.0.0.1:8081;
        }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF
my $d = $t->testdir();

foreach my $name ('localhost') {
	system('openssl req -x509 -new '
		. "-config $d/openssl.conf -subj /CN=$name/ "
		. "-out $d/$name.crt -keyout $d/$name.key "
		. ">>$d/openssl.out 2>&1") == 0
		or die "Can't create certificate for $name: $!\n";
}

$t->run_daemon(\&http_daemon, port(8081));
$t->run();
$t->waitforsocket('127.0.0.1:' . port(8081));

###############################################################################

my ($s, $sid, $frames, $frame);
my @bad_statuses = (100, 102, 104 .. 199);
foreach my $status (@bad_statuses) {
	like(http_get("/$status"), qr|\AHTTP/1\.1 200 |, "unhandlable request status $status");
}

foreach my $s (Test::Nginx::HTTP2->new(), Test::Nginx::HTTP3->new()) {
	foreach my $status (101, @bad_statuses) {
                my $sid = $s->new_stream({ host => 'localhost', path => "/$status" });
		my $frames = $s->read(all => [{ sid => $sid, fin => 1 }]);
		my (@frame) = grep { $_->{type} eq "HEADERS" } @$frames;
		if ($status == 101) {
			is($#frame, 0);
			is($frame[0]->{headers}->{':status'},
			   502, "unhandlable request status $status");
		} else {
			is($#frame, 1);
			is($frame[0]->{headers}->{':status'},
			   $status, "handlable request status $status");
			is($frame[1]->{headers}->{':status'}, 200, "final response");
		}
	}
}
###############################################################################

sub http_daemon {
	my ($port) = @_;
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1:' . $port,
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	local $SIG{PIPE} = 'IGNORE';

	while (my $client = $server->accept()) {
		$client->autoflush(1);

		if ($port == port(8083)) {
			sleep 3;

			close $client;
			next;
		}

		my $headers = '';
		my $uri = '';

		while (<$client>) {
			$headers .= $_;
			last if (/^\x0d?\x0a?$/);
		}

		$uri = $1 if $headers =~ /^\S+\s+([^ ]+)\s+HTTP/i;
		next if $uri eq '';

		if ($uri =~ qr|\A/(1[0-9][0-9])\z|) {
			print $client <<EOF;
HTTP/1.1 $1 Something
Link: silly

HTTP/1.1 200 OK
Connection: close

EOF
		} else {
			print $client <<EOF;
HTTP/1.1 404 Not Found
Connection: close

EOF
		}
		close $client;
	}
}

###############################################################################
