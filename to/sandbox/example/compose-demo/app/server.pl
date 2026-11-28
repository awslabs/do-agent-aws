#!/usr/bin/perl
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# compose-demo web service: a dependency-free HTTP/1.0 server (Perl core modules
# only, so the image build downloads nothing beyond its base image).
#   GET /health                -> 200 {"status":"ok","instance_id":"<hostname>"}
#   GET /sum?a=<int>&b=<int>   -> 200 {"sum":<a+b>}, 400 when a or b is not an integer
#   anything else              -> 404 {"error":"not found"}
# instance_id is the container hostname, which Docker sets to the short
# container id: a reader of /health can be matched to the container that served it.
# Exit status on SIGTERM (docker compose down): 0 when this instance served every
# request app/check.pl makes (%CHECK_REQUESTS below), 3 otherwise. The engine
# records it, so a verifier can tell that the stack's checks reached this
# instance without trusting anyone's report.
use strict;
use warnings;
use IO::Socket::INET;

# Sys::Hostname is not in perl-base; Docker writes the hostname to /etc/hostname
# and sets HOSTNAME.
sub container_hostname {
	if (open(my $fh, '<', '/etc/hostname')) {
		my $h = <$fh>;
		close $fh;
		if (defined $h) {
			$h =~ s/\s+\z//;
			return $h if length $h;
		}
	}
	return $ENV{HOSTNAME} || 'unknown';
}

my $port     = $ENV{PORT} || 8080;
my $instance = container_hostname();
my $server   = IO::Socket::INET->new(
	LocalAddr => '0.0.0.0',
	LocalPort => $port,
	Listen    => 16,
	ReuseAddr => 1,
	Proto     => 'tcp',
) or die "compose-demo: cannot listen on :$port: $!\n";

# The requests app/check.pl makes and the status each must get; keep in sync.
my %CHECK_REQUESTS = ('/sum?a=2&b=40' => 200, '/sum?a=x&b=1' => 400, '/nope' => 404);
my %checks_served;

$| = 1;
# PID 1 in the container: without a handler SIGTERM is ignored and
# "docker compose down" waits for its kill timeout.
$SIG{TERM} = $SIG{INT} = sub { exit(scalar(keys %checks_served) == scalar(keys %CHECK_REQUESTS) ? 0 : 3) };
print "compose-demo web listening on :$port instance_id=$instance\n";

my %reason = (200 => 'OK', 400 => 'Bad Request', 404 => 'Not Found');

while (my $client = $server->accept) {
	my ($status, $body) = (404, '{"error":"not found"}');
	my $line;
	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm 5;
		$line = <$client>;
		while (defined $line) {
			my $header = <$client>;
			last if !defined $header || $header =~ /^\r?\n$/;
		}
		alarm 0;
		1;
	} or do { alarm 0; close $client; next; };
	next unless defined $line;

	my ($method, $target) = $line =~ m{^(\S+)\s+(\S+)};
	if (defined $target && $method eq 'GET') {
		my ($path, $query) = split /\?/, $target, 2;
		if ($path eq '/health') {
			($status, $body) = (200, qq({"status":"ok","instance_id":"$instance"}));
		} elsif ($path eq '/sum') {
			my %q = map { my ($k, $v) = split /=/, $_, 2; ($k, defined $v ? $v : '') } split /&/, (defined $query ? $query : '');
			if (defined $q{a} && defined $q{b} && $q{a} =~ /^-?\d{1,9}$/ && $q{b} =~ /^-?\d{1,9}$/) {
				($status, $body) = (200, '{"sum":' . ($q{a} + $q{b}) . '}');
			} else {
				($status, $body) = (400, '{"error":"a and b must be integers"}');
			}
		}
	}
	$checks_served{$target} = 1 if defined $target && exists $CHECK_REQUESTS{$target} && $CHECK_REQUESTS{$target} == $status;
	print $client "HTTP/1.0 $status $reason{$status}\r\n"
		. "Content-Type: application/json\r\n"
		. "Content-Length: " . length($body) . "\r\n"
		. "Connection: close\r\n\r\n"
		. $body;
	close $client;
}
