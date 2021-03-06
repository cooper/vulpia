# Copyright (c) 2009-16, Mitchell Cooper
#
# @name:            "ircd::server::linkage"
# @package:         "server::linkage"
# @description:     "manages server connections"
# @version:         ircd->VERSION
#
# @no_bless
# @preserve_sym
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package server::linkage;

use warnings;
use strict;

use utils qw(conf v notice irc_lc);

our ($api, $mod, $me, $pool, $conf);
my $timers  = \%ircd::link_timers;
my $futures = \%ircd::link_futures;
my $conns   = \%ircd::link_connections;

sub init {
    $pool->on('server.new'      => \&new_server,      with_eo => 1);
    $pool->on('connection.done' => \&connection_done, with_eo => 1);
    return 1;
}

# connect_server()
#
# attempt to connect to a server in the configuration.
#
# if the server is connected already
#   (whether directly or indirectly),
#   returns an error string.
#
# if we're already trying to connect,
#   returns an error string.
#
# if some other IMMEDIATE error occurs,
#   returns that error string.
#
# if no immediate error occurs,
#   returns nothing.
#
# however, because the connection is asynchronous,
# returning no error does not guarantee success.
#
sub connect_server {
    my ($server_name, $auto_only) = (irc_lc(shift), shift);

    # server is already registered/known.
    if ($pool->lookup_server_name($server_name)) {
        return 'Server exists';
    }

    # we're already trying to connect.
    if ($timers->{$server_name} || $futures->{$server_name}) {
        return 'Already trying to connect';
    }

    # does the server exist in configuration?
    my %serv = $conf->hash_of_block(['connect', $server_name]);
    if (!scalar keys %serv) {
        return 'Server does not exist in configuration';
    }

    # is the server supposed to autoconnect?
    my $interval = $serv{auto_timeout} || $serv{auto_timer} || -1;
    if ($auto_only && $interval == -1) {
        return 'Server not configured for autoconnect';
    }

    # not using a timer.
    if ($interval == -1) {
        _establish_connection($server_name, undef, %serv);
    }

    # create a timer.
    else {
        my $timer = $timers->{$server_name} = IO::Async::Timer::Periodic->new(
            first_interval => 0,
            interval => $interval,
            on_tick  => sub {
                my $timer = shift;
                _establish_connection($server_name, $timer, %serv);
            }
        );
        $timer->start;
        $::loop->add($timer);
    }

    return;
}

sub _establish_connection {
    my ($server_name, $timer, %serv) = @_;

    #%s (%s) on port %d (Attempt %d)
    if ($timer) {
        my $attempt = ++$timer->{_attempt};
        notice(connect_attempt =>
            $server_name, $serv{address}, $serv{port}, $attempt
        );
    }

    # SSL?
    my ($connect, %ssl_opts) = 'connect';
    if ($serv{ssl}) {
        require IO::Async::SSL;
        $connect = 'SSL_connect';
        %ssl_opts = (
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
            on_ssl_error    => sub { ircd::_conn_close('SSL error: '.$_[1], @_) }
        );
        # TODO: (#28) fingerprints
    }

    # protocol?
    my $proto = 'jelp'; # fallback
    if ($serv{ircd}) {
        my %ircd = server::protocol::ircd_support_hash($serv{ircd});
        $proto = $ircd{link_type};
    }

    # create a future that attempts to connect.
    my $connect_future = $::loop->$connect(
        addr => {
            family   => index($serv{address}, ':') != -1 ? 'inet6' : 'inet',
            socktype => 'stream',
            port     => $serv{port},
            ip       => $serv{address}
        },
        @ircd::stream_opts,
        %ssl_opts
    );

    # create a future to time out after 5 seconds.
    # create a third future that will wait for whichever comes first.
    my $timeout_future = $::loop->timeout_future(after => 5);
    my $future = Future->wait_any($connect_future, $timeout_future);

    # retain the future.
    $futures->{$server_name} = $future;

    # once this is ready, the connection succeeded or failed.
    $future->on_ready(sub {
        delete $futures->{$server_name};
        my $f = shift;

        # it failed.
        if (my $e = $f->failure) {
            chomp $e;
            return if $f->is_cancelled;
            notice(connect_fail => $server_name, length $e ? $e : 'Timeout');
            return;
        }

        # success!
        my $socket = $f->get;
        notice(connect_success => $server_name);

        # if it's a stream already, it was probably SSL.
        my $stream;
        if ($socket->isa('IO::Async::Stream')) {
            $stream = $socket;
        }
        else {
            $stream = IO::Async::Stream->new(handle => $socket);
        }
        ircd::configure_stream($stream);

        # create a connection object.
        my $conn = $conns->{$server_name} =
            $pool->new_connection(stream => $stream);
        $conn->fire('looks_like_server');

        # add to loop.
        $::loop->add($stream);

        # set up the connection.
        $conn->{i_initiated} = 1;
        $conn->{want} = $server_name; # server name to expect in return.

        # this is where proto modules will send their initial commands
        $conn->{link_type} = $proto;
        $conn->fire("initiate_${proto}_link");

    });
}

# cancel_connection()
#
# cancels a connection timer.
# this does not necessarily mean that it was unsuccessful.
#
# if the server is not connected but we're trying to connect,
#   return true,
#   cancel the connection attempt.
#
# if the server is connected,
#   return false.
#
# this is also called by the server.new callback below,
# e.g. when the server becomes connected or is introduced
# by some other means.
#
sub cancel_connection {
    my ($server_name, $keep_conn) = (irc_lc(shift), shift);
    my $ret;

    # cancel timer
    my $timer = delete $timers->{$server_name};
    if ($timer) {
        $timer->stop if $timer->is_running;
        $timer->loop->remove($timer) if $timer->loop;
        $ret++;
    }

    # cancel pending future
    my $future = delete $futures->{$server_name};
    $future->cancel if $future;

    # close connection
    unless ($keep_conn) {
        my $conn = delete $conns->{$server_name};
        $conn->{dont_reconnect}++ if $conn;
        $conn->done('Connection canceled') if $conn;
    }

    return $ret;
}

# new server event.
#
# this applies to ANY server that becomes recognized by the pool.
# if any connection timers exist for a server that was introduced
# successfully, they are terminated here.
#
sub new_server {
    my $server = shift;
    my $name   = irc_lc($server->{name});
    cancel_connection($name, 1);
}

# connection done event.
# note: {type, location, server, stream} are deleted at this point
# as well as all events
sub connection_done {
    my ($conn, $event, $reason) = @_;
    my $server_name = $conn->{name} // $conn->{want};
    return unless length $server_name;

    # we already have a connection timer going.
    # this means that a connection object was created,
    # (the connection was actually established),
    # but some error occurred before finishing registration.
    if ($timers->{$server_name}) {
        notice(connect_fail => $server_name, $reason);
        return;
    }

    # if we're supposed to autoconnect but don't have a timer going, start one now.
    connect_server($server_name, 1) unless $conn->{dont_reconnect};

}

$mod
