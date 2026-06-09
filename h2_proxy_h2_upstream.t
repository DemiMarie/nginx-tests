#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for HTTP/2 protocol with error_page directive.

###############################################################################

use warnings;
use strict;
use feature 'signatures';

use Test::More;
use Data::Dumper;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http http_v2/)->plan(0)
	->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%
    early_hints 1;
    error_log /dev/tty;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        http2 on;
        lingering_close off;

        error_page 400 = /close;

        location / {
            proxy_pass http://127.0.0.1:8081;
            proxy_http_version 2;
            early_hints 1;
        }

        location /close {
            return 444;
        }
    }
}

EOF

$t->run_daemon(\&http_daemon);
$t->run();

###############################################################################

# tests for socket leaks with "return 444" in error_page

my ($sid, $frames, $frame);

# make sure there is no socket leak when the request is rejected
# due to missing mandatory ":scheme" pseudo-header and "return 444;"
# is used in error_page 400 (ticket #274)

open (my $flags, '>', "/dev/tty") or die "Failed to open /dev/tty: $!";
sub print_frames {
    print { $flags } (Dumper(get(@_)));
}

sub get_frames ($frames) {
        my $seen_data = 0;
        my $previous_status = 199;
        map {
                if ($_->{type} == 'HEADERS') {
                        cmp_ok($previous_status, '<', 200);
                } elsif ($_->{type} == 'DATA') {
                        cmp_ok($previous_status, '>=', 200);
                    }
        };
}


print_frames("/multi");
print_frames("/header");

###############################################################################

sub get {
	my ($path) = @_;
        my $host = 'localhost';

	my $s = Test::Nginx::HTTP2->new();
	my $sid = $s->new_stream({ host => '127.0.0.1:8080', path => $path });
	return $s->read(all => [{ sid => $sid, fin => 1 }]);
}

sub http_daemon {
	my $once = 1;
	my $client;
	my $server = IO::Socket::INET->new(
		Proto => 'tcp',
		LocalHost => '127.0.0.1:' . port(8081),
		Listen => 5,
		Reuse => 1
	)
		or die "Can't create listening socket: $!\n";

	while ($client = $server->accept()) {
		$client->autoflush(1);
		$client->sysread(my $buf, 24) == 24 or next; # preface

		my $c = Test::Nginx::HTTP2->new(1, socket => $client,
			pure => 1, preface => "") or next;

		$c->h2_settings(0);
		$c->h2_settings(1);

		my $frames = $c->read(all => [{ fin => 4 }]);
		my ($frame) = grep { $_->{type} eq "HEADERS" } @$frames;
		my $sid = $frame->{sid};
		my $uri = $frame->{headers}{':path'};

		if ($uri eq '/') {
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS');

		} elsif ($uri eq '/multi') {
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
				{ name => 'link', value => 'file:///dev/null' },
			]}, $sid);
			$c->h2_body('SEE-THIS', { body_more => 1 });

			select undef, undef, undef, 0.1;
			$c->h2_body('AND-THIS');

		} elsif ($uri eq '/timeout') {
			sleep 3;

			$c->new_stream({ headers => [
				{ name => ':status', value => '200' },
			]}, $sid);

		} elsif ($uri eq '/header') {
			select undef, undef, undef, 1.1;

			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '100' },
				{ name => 'link', value => 'file:///dev/null' },
			]}, $sid);
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '102' },
				{ name => 'link', value => 'file:///dev/null' },
			]}, $sid);
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '103' },
				{ name => 'link', value => 'silly' },
			]}, $sid);
			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
				{ name => 'accept-encoding', value => 'silly' },
			]}, $sid);
			$c->h2_body('SEE-THIS');

		} elsif ($uri eq '/body') {

			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '200' },
			]}, $sid);
			$c->h2_body('SEE-THIS-', { body_more => 1 });

			select undef, undef, undef, 1.1;
			$c->h2_body('AND-THIS');

		} else {

			$c->new_stream({ body_more => 1, headers => [
				{ name => ':status', value => '404' },
			]}, $sid);
			$c->h2_body("Oops, '$uri' not found");
		}
	}
}

################################################################################
