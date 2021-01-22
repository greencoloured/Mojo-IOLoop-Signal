package Mojo::IOLoop::Signal;
use Mojo::Base 'Mojo::EventEmitter';

use Config;
use Mojo::IOLoop;
use Scalar::Util 'weaken';

our $VERSION = '0.002';
my %SIGNAME = map { $_ => 1 } split /\s+/, $Config{sig_name};
our %EXCLUDE = map { $_ => 1 } qw(PIPE KILL ZERO);

sub _instance {
    state $SELF = __PACKAGE__->_new;
    ref $_[0] ? $_[0] : $SELF
}

sub singleton { _instance(shift) }

sub new { die "Cannot construct Mojo::IOLoop::Signal objects. It's a singleton.\n" }

sub _new {
    my $class = shift;
    my $reactor =  Mojo::IOLoop->singleton->reactor;
    my $is_ev;
    if ($reactor->isa('Mojo::Reactor::EV')) {
        $is_ev = 1;
    } elsif ($reactor->isa('Mojo::Reactor::Poll')) {
        $is_ev = 0;
    } else {
        die "Unsupported reactor: " . ref($reactor);
    }
    bless { 
        pid     => $$,
        is_ev   => $is_ev, 
        reactor => $reactor,
        keep    => {}, 
        signals => [],
    }, $class;
}

sub DESTROY {
    shift->stop unless ${^GLOBAL_PHASE} eq 'DESTRUCT';
}

sub stop {
    my $self = _instance(shift);
    if (!$self->{is_ev}) {
        $self->{reactor}->remove(delete $self->{read}) if $self->{read};
        $self->{reactor}->remove(delete $self->{write}) if $self->{write};
        for my $name (keys %{$self->{keep}}) {
            $SIG{$name} = $self->{keep}{$name};
        }
        $self->emit($_, $_, ($_ eq 'CHLD' ? (0, undef) : ())) for splice @{$self->{signals}};
    }
    $self->{keep} = {};
    $self;
}

sub _forked {
    my $self = shift;
    $self->{pid} = $$;
    $self->{reactor}->remove(delete $self->{read}) if $self->{read};
    $self->{reactor}->remove(delete $self->{write}) if $self->{write};
    $self->_watch;
    $self->{reactor}->watch($self->{write}, 0, 1) if @{$self->{signals}};
}

sub _is_signame {
    my ($class, $name) = @_;
    $SIGNAME{$name} and !$EXCLUDE{$name};
}

sub once {
    my ($self, $name, $cb) = (_instance(shift), @_);
    $self->SUPER::once($name, $cb);
}

sub _watch {
    my $self = shift;
    pipe my $read, my $write;
    $write->autoflush(1);
    $self->{write} = $write;
    $self->{read} = $read;
    $self->{reactor}->io($read => sub {
        my ($reactor, $w) = @_;
        return unless $self;
        return $self->emit(error => "writing on read pipe!") if $w;
        return $self->_forked unless $$ eq $self->{pid};
        my $rc = sysread $self->{read}, my $b, 1024;
        if ($rc) {
            $self->emit($_, $_, ($_ eq 'CHLD' ? (0, undef) : ())) for splice @{$self->{signals}};
        } else {
            return $self->emit(error => "pipe read: $!");
        }
    });
    $self->{reactor}->watch($read, 1, 0);
    $self->{reactor}->io($write => sub {
        my ($reactor, $w) = @_;
        return unless $self;
        return $self->emit(error => "reading on write pipe!") unless $w;
        return $self->_forked unless $$ eq $self->{pid};
        if (@{$self->{signals}}) {
            my $rc = syswrite $self->{write}, "1"; 
            return $self->emit(error => "pipe write: $!") unless $rc;
        }
        $self->{reactor}->watch($write, 0, 0);
    });
    $self->{reactor}->watch($write, 0, 0);
}

sub on {
    my ($self, $name, $cb) = (_instance(shift), @_);
    if ($self->_is_signame($name) and !exists $self->{keep}{$name}) {
        weaken $self;
        if ($self->{is_ev}) {
            if ($name eq 'CHLD') {
                $self->{keep}{$name} = EV::child(0, 0, sub { 
                    return unless $self;
                    my $w = $self->{keep}{$name};
                    $self->emit($name, $name, $w->rpid, $w->rstatus);
                });
            } else {
                $self->{keep}{$name} = EV::signal($name => sub { 
                    return unless $self;
                    $self->emit($name, $name);
                });
            }
        } else {
            $self->_watch unless $self->{write};
            $self->{keep}{$name} = $SIG{$name} || 'DEFAULT';
            $SIG{$name} = sub {
                return unless $self;
                push @{$self->{signals}}, $name;
                if ($self->{write}) {
                    $self->{reactor}->watch($self->{write}, 0, 1);
                } else {
                    warn "signal with closed pipe!"; 
                }
            };
        }
    }
    $self->SUPER::on($name, $cb);
}

sub unsubscribe {
    my ($self, $name, @arg) = (_instance(shift), @_);
    $self->SUPER::unsubscribe($name, @arg);
    if ($self->_is_signame($name) and !$self->has_subscribers($name)) {
        if ($self->{is_ev}) {
            delete $self->{keep}{$name};
        } else {
            $SIG{$name} = delete $self->{keep}{$name};
        }
    }
    if (!%{$self->{keep}}) {
        $self->stop;
    }
    $self;
}

1;
__END__

=encoding utf-8

=head1 NAME

Mojo::IOLoop::Signal - Non-blocking signal handler

=head1 SYNOPSIS

  use Mojo::IOLoop::Signal;

  Mojo::IOLoop::Signal->on(TERM => sub {
    my ($self, $name) = @_;
    warn "Got $name signal";
  });

  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head1 DESCRIPTION

Mojo::IOLoop::Signal is a Mojo::IOLoop based, non-blocking signal handler.

=head1 EVENTS

Mojo::IOLoop::Signal inherits all events from L<Mojo::EventEmitter> and can emit the following new ones.


=head2 signal names such as TERM, INT, QUIT, ...

See C<< $Config{sig_name} >> for a complete list.

  $ perl -MConfig -e 'print $Config{sig_name}'
  ZERO HUP INT QUIT ILL TRAP ABRT EMT FPE KILL BUS SEGV SYS PIPE ALRM TERM URG STOP TSTP CONT CHLD TTIN TTOU IO XCPU XFSZ VTALRM PROF WINCH INFO USR1 USR2 IOT

=head1 METHODS

Mojo::IOLoop::Signal inherits all methods from L<Mojo::EventEmitter> and implements the following new ones.

=head2 stop

  Mojo::IOLoop::Signal->stop;

Stop watching signals. You might want to use C<stop> like:

  Mojo::IOLoop::Signal->on(HUP => sub {
    my ($self, $name) = @_;
    # log rotate
  });
  Mojo::IOLoop::Signal->on(TERM => sub {
    my ($self, $name) = @_;
    $self->stop;
  });
  Mojo::IOLoop->start;

=head1 AUTHOR

Shoichi Kaji <skaji@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2016 Shoichi Kaji <skaji@cpan.org>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
