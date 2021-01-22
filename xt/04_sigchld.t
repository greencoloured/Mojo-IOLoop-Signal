use strict;
use warnings;
use FindBin ();
use lib "$FindBin::Bin/lib";

use Test2::IPC;
use Test::More;
use Test::Utils qw(test_run note_sig);
use POSIX ":sys_wait_h";

use constant TEST_EXIT => 2;

sub run {
	test_run(shift, [], sub {
		require Mojo::IOLoop::Signal;

		is ref Mojo::IOLoop->singleton->reactor, $_[1], "using $_[1]";

		my $who = 'prefork';
		my $pid;
		Mojo::IOLoop::Signal->on(CHLD => sub { 
			my (undef, $sig, $waitpid, $status) = @_;
			note_sig $who, 'got', 'CHLD';
			if (not $waitpid) {
				while (1) {
					$waitpid = waitpid $pid, WNOHANG;
					if ($waitpid < 0) {
						fail "failed to collect child: $pid";
						last;
					} elsif ($waitpid > 0) {
						$status = $?;
						last;
					}
					Mojo::IOLoop->timer(0.01 => sub { });
					Mojo::IOLoop->one_tick;
				}
			}
			my $rsig  = $status & 127;
			my $rexit = $status >> 8;
			is $sig, 'CHLD',      'got CHLD';
			is $waitpid, $pid,    'child pid correct';
			is $rsig, 0,          'child exited without signal';
			is $rexit, TEST_EXIT, 'child exited with '.TEST_EXIT;
			Mojo::IOLoop->stop;
		});
		Mojo::IOLoop->timer(0 => sub { 
			$pid = fork // die $!;
			if ($pid) {
				$who = 'parent';
				note "fork";
			} else {
				$who = 'child';
				exit TEST_EXIT;
			}
		});
		Mojo::IOLoop->timer(3 => sub {
			fail "timeout";
			Mojo::IOLoop->stop;
		});
		Mojo::IOLoop->start;

		return 0;
	});
}

subtest poll => sub { run('Mojo::Reactor::Poll') };
subtest ev   => sub { run('Mojo::Reactor::EV') };

done_testing;
