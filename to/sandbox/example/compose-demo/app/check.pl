#!/usr/bin/perl
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# compose-demo stack tests. Run as the tests container's MAIN process
# (docker compose run --rm -T tests), never through docker exec: in cloud
# sandboxes docker exec can reach the VM filesystem instead of the container's.
# Waits for the web service (there is no Compose healthcheck, for the same
# reason), runs the checks, prints one "ok"/"not ok" line per check and a final
# RESULT_JSON line, and exits 0 only when every check passed.
use strict;
use warnings;
use IO::Socket::INET;

my $base = shift // 'http://web:8080';
my ($host, $port) = $base =~ m{^http://([^:/]+):(\d+)} or die "check.pl: bad base url $base\n";

sub get {
	my ($path) = @_;
	my $s = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => 5)
		or return (0, '');
	print $s "GET $path HTTP/1.0\r\nHost: $host\r\n\r\n";
	local $/;
	my $resp = <$s>;
	close $s;
	$resp = '' unless defined $resp;
	my ($code) = $resp =~ m{^HTTP/\d\.\d (\d{3})};
	my ($body) = $resp =~ m{\r\n\r\n(.*)\z}s;
	return ($code // 0, $body // '');
}

my $ready = 0;
for (1 .. 60) {
	my ($code) = get('/health');
	if ($code == 200) { $ready = 1; last }
	sleep 1;
}
print $ready ? "web ready\n" : "web not ready after 60 s\n";

# Keep the number of checks in sync with EXPECTED_CHECKS in
# run-deterministic.sh and verify-agent-report.py.
my @checks = (
	['health answers 200 with status ok', sub { my ($c, $b) = get('/health'); $c == 200 && $b =~ /"status":"ok"/ }],
	['health reports an instance id',     sub { my ($c, $b) = get('/health'); $b =~ /"instance_id":"[A-Za-z0-9._-]+"/ }],
	['sum adds two integers',             sub { my ($c, $b) = get('/sum?a=2&b=40'); $c == 200 && $b eq '{"sum":42}' }],
	['sum rejects a non-integer',         sub { my ($c, $b) = get('/sum?a=x&b=1'); $c == 400 }],
	['unknown path answers 404',          sub { my ($c, $b) = get('/nope'); $c == 404 }],
);

my ($passed, $failed) = (0, 0);
for my $check (@checks) {
	if ($ready && $check->[1]->()) {
		$passed++;
		print "ok - $check->[0]\n";
	} else {
		$failed++;
		print "not ok - $check->[0]\n";
	}
}
my (undef, $health) = get('/health');
my ($instance) = $health =~ /"instance_id":"([A-Za-z0-9._-]*)"/;
$instance //= '';
my $total = scalar @checks;
print qq(RESULT_JSON {"suite":"compose-demo","total":$total,"passed":$passed,"failed":$failed,"instance_id":"$instance"}\n);
exit($failed == 0 && $passed == $total ? 0 : 1);
