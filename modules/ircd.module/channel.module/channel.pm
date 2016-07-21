# Copyright (c) 2009-16, Mitchell Cooper
#
# @name:            "ircd::channel"
# @package:         "channel"
# @description:     "represents an IRC channel"
# @version:         ircd->VERSION
# @no_bless:        1
# @preserve_sym:    1
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package channel;

use warnings;
use strict;
use feature 'switch';
use parent 'Evented::Object';

use utils qw(conf v notice match ref_to_list);
use List::Util qw(first max);
use Scalar::Util qw(blessed);

our ($api, $mod, $pool, $me);

#   === Channel mode types ===
#
#   type            n   description                                 e.g.
#   ----            -   -----------                                 ----
#
#   normal          0   never has a parameter                       +m
#
#   parameter       1   requires parameter when set and unset       n/a
#
#   parameter_set   2   requires parameter only when set            +l
#
#   list            3   list-type mode                              +b
#
#   status          4   status-type mode                            +o
#
#   key             5   like type 1 but visible only to members     +k
#                       and consumes parameter when unsetting
#                       only if present (keys are very particular!)

# create a channel.
sub new {
    my ($class, %opts) = @_;
    return bless {
        users => [],
        modes => {},
        %opts
    }, $class;
}

# channel mode is set.
sub is_mode {
    my ($channel, $name) = @_;
    return $channel->{modes}{$name};
}

# current parameter for a set mode, if any.
sub mode_parameter {
    my ($channel, $name) = @_;
    return $channel->{modes}{$name}{parameter};
}

# low-level mode set.
# takes an optional parameter.
# $channel->set_mode('moderated');
sub set_mode {
    my ($channel, $name, $parameter) = @_;
    $channel->{modes}{$name} = {
        parameter => $parameter,
        time      => time
        # list for list modes and status
    };
    L("$$channel{name} +$name");
    return 1
}

# low-level mode unset.
sub unset_mode {
    my ($channel, $name) = @_;
    return unless $channel->is_mode($name);
    delete $channel->{modes}{$name};
    L("$$channel{name} -$name");
    return 1;
}

# list has something.
sub list_has {
    my ($channel, $name, $what) = @_;
    return unless $channel->{modes}{$name};
    return 1 if defined first { $_ eq $what } $channel->list_elements($name);
}

# something matches in an expression list.
# returns the match if there is one.
sub list_matches {
    my ($channel, $name, $what) = @_;
    return unless $channel->{modes}{$name};
    return first { match($what, $_) } $channel->list_elements($name);
}

# returns an array of list elements.
sub list_elements {
    my ($channel, $name, $all) = @_;
    return unless $channel->{modes}{$name};
    my @list = ref_to_list($channel->{modes}{$name}{list});
    if ($all)  { return @list }
    return map { $_->[0]      } @list;
}

# adds something to a list mode.
sub add_to_list {
    my ($channel, $name, $parameter, %opts) = @_;

    # first item. wow.
    $channel->{modes}{$name} = {
        time => time,
        list => []
    } unless $channel->{modes}{$name};

    # no duplicates plz.
    return if $channel->list_has($name, $parameter);

    # add it.
    L("$$channel{name}: adding $parameter to $name list");
    my $array = [$parameter, \%opts];
    push @{ $channel->{modes}{$name}{list} }, $array;

    return 1;
}

# removes something from a list.
sub remove_from_list {
    my ($channel, $name, $what) = @_;
    return unless $channel->list_has($name, $what);

    my @new = grep {
        $_->[0] ne $what
    } ref_to_list($channel->{modes}{$name}{list});
    $channel->{modes}{$name}{list} = \@new;

    L("$$channel{name}: removing $what from $name list");
    return 1;
}

# user joins channel
sub add {
    my ($channel, $user) = @_;
    return if $channel->has_user($user);

    # add the user to the channel.
    push @{ $channel->{users} }, $user;

    # note: as of 5.91, after-join (user_joined) event is fired in
    # mine.pm:           for locals
    # core_scommands.pm: for nonlocals.

    notice(user_join => $user->notice_info, $channel->name);
    return $channel->{time};
}

# remove a user.
# this could be due to any of part, quit, kick, server quit, etc.
sub remove {
    my ($channel, $user) = @_;

    # remove the user from status lists
    foreach my $name (keys %{ $channel->{modes} }) {
        $channel->remove_from_list($name, $user) if $me->cmode_type($name) == 4;
    }

    # remove the user.
    my @new = grep { $_ != $user } $channel->users;
    $channel->{users} = \@new;

    # delete the channel if this is the last user.
    $channel->destroy_maybe();

    return 1;
}

# alias remove_user.
sub remove_user;
*remove_user = *remove;

# user is on channel.
sub has_user {
    my ($channel, $user) = @_;
    return first { $_ == $user } $channel->users;
}

# low-level channel time set.
sub set_time {
    my ($channel, $time) = @_;
    if ($time > $channel->{time}) {
        L("warning: setting time to a lower time from $$channel{time} to $time");
    }
    $channel->{time} = $time;
}

# ->handle_modes()
#
# handles named modes at a low level.
#
# you may want to use ->do_modes() or ->do_mode_string() instead,
# as these are high-level methods which also notify local clients and uplinks.
#
# See issues #77 and #101 for background information.
#
sub handle_modes {
    my ($channel, $source, $modes, $force, $over_protocol) = @_;
    my @changes;

    # $modes has to be an arrayref.
    if (!ref $modes || ref $modes ne 'ARRAY') {
        L("Modes are not in the proper arrayref form; mode handle aborted");
        return;
    }

    # $modes has to have an even number of elements.
    if (@$modes % 2) {
        L("Odd number of elements passed; mode handle aborted");
        return;
    }

    # if over_protocol is specified but not a code reference, fall back
    # to JELP UID lookup function for compatibility.
    if ($over_protocol && ref $over_protocol ne 'CODE') {
        $over_protocol = sub { $pool->lookup_user(@_) };
    }

    # apply each mode.
    my @modes = @$modes; # explicitly make a copy
    MODE: while (my ($name, $param) = splice @modes, 0, 2) {

        # extract the state.
        my $state = 1;
        my $first = \substr($name, 0, 1);
        if ($$first eq '-' || $$first eq '+') {
            $state  = $$first eq '+';
            $$first = '';
        }

        # find the mode type.
        my $type = $me->cmode_type($name);
        if (!defined $type || $type == -1) {
            L("Mode '$name' is not known to this server; skipped");
            next MODE;
        }

        # if the mode requires a parameter but one was not provided,
        # we have no choice but to skip this.
        #
        # these are returned by ->cmode_takes_parameter: NOT mode types
        #     1 = always takes param
        #     2 = takes param, but valid if there isn't,
        #         such as list modes like +b for viewing
        #
        my $takes = $me->cmode_takes_parameter($name, $state) || 0;
        if (!defined $param && $takes == 1) {
            L("Mode '$name' is missing a parameter; skipped");
            next MODE;
        }

        # this is for compatibility with mode blocks that use something like:
        # push @{ $mode->{parameters} }, ... to add a parameter to the
        # resultant. it works by resetting the parameter list for each mode,
        # such that it will probably never exceed a length of one.
        my $params_before = 0;
        my $parameters = [];

        # don't allow this mode to be changed if the test fails
        # *unless* force is provided.
        my ($win, $moderef) = $pool->fire_channel_mode($channel, $name, {
            channel => $channel,        # the channel
            server  => $me,             # the server perspective
            source  => $source,         # the source of the mode change (user or server)
            state   => $state,          # setting or unsetting
            setting => $state,          # to satisfy matthew
            param   => $param,          # the parameter for this particular mode
            params  => $parameters,     # the parameters for the resulting mode string
            force   => $force,          # true if permissions should be ignored
            proto   => $over_protocol,  # true if IDs used rather than nicks/names

            # source can set simple modes.
            has_basic_status => $force || $source->isa('server') ? 1
                                : $channel->user_has_basic_status($source),

            # a function to look up a user by nickname or UID.
            # this exists only for compatibility; newer ->do_modes() and friends
            # use user objects. note that this checks if it's already an object.
            user_lookup => sub {
                my $p = $_[0];
                return $p if blessed $p && $p->isa('user');
                return $over_protocol->(@_) if $over_protocol;
                return $pool->lookup_user_nick(@_);
            }

        });

        # Determining whether to send ERR_CHANOPRIVSNEEDED
        #
        # Source is a local user?
        #   No..................................... DO NOT SEND
        #   Yes. Mode block set send_no_privs?
        #       Yes................................ SEND
        #       No. Mode block returned true?
        #           Yes............................ DO NOT SEND
        #           No. User has +h or higher?
        #               Yes........................ DO NOT SEND
        #               No. Mode block set hide_no_privs?
        #                   Yes.................... DO NOT SEND
        #                   No..................... SEND
        #
        if ($source->isa('user') && $source->is_local) {
            my $no_status = !$win && !$moderef->{has_basic_status}
                && !$moderef->{hide_no_privs};
            my $yes = $moderef->{send_no_privs} || $no_status;
            $source->numeric(ERR_CHANOPRIVSNEEDED => $channel->name) if $yes;
        }

        # block returned false; cancel the change.
        next MODE if !$win;

        # so this is the "new" way to set a parameter. rather than pushing
        # to the parameter list, set the param key.
        push @$parameters, $moderef->{param} if defined $moderef->{param};

        # if this mode requires a parameter but the param count before handling
        # the mode is the same as after, something didn't work.
        # for example, a mode handler might not be present if a module isn't
        # loaded. just ignore this mode in such a case.
        next MODE if scalar @$parameters <= $params_before && $takes;

        # the parameter is extracted in case it was modified by the mode
        # block. the only place $param is used from hereo n is below in
        # ->(un)set_mode() which is only called for modes of type 1 and 2.
        $param = @$parameters[$#$parameters] if @$parameters;

        # prior to 11.38, mode blocks could push an array reference in the form
        # of [ USER RESPONSE, SERVER RESPONSE ] to the parameter list. this was
        # only used for UIDs and nicknames and is now deprecated in favor of
        # user objects.
        if (ref $param && ref $param eq 'ARRAY') {
            $param =
                $me->uid_to_user($param->[1])        ||
                $pool->lookup_user_nick($param->[0]) || $param;
            L(
                "Pushing an array reference to the '$name' parameter list is " .
                "deprecated; attempted to convert to user object"
            );
        }

        # SAFE POINT:
        # from here we can assume that the mode will be set or unset.
        # it has passed all the tests and will certainly be applied.

        # it is a "normal" type mode.
        if ($type == 0) {
            my $do = $state ? 'set_mode' : 'unset_mode';
            $channel->$do($name);
        }

        # it is a mode with a simple parameter.
        # does not include lists, status modes, key mode.
        elsif ($type == 1 || $type == 2) {
            $channel->set_mode($name, $param)   if  $state;
            $channel->unset_mode($name)         if !$state;
        }

        # add it to the list of changes.
        my $prefixed_name = ($state ? '' : '-').$name;
        push @changes, $prefixed_name, $param;

    }

    return \@changes;
}

# ->handle_mode_string()
#
# handles a mode string at a low level.
#
# this is a low-level function that only sets the modes.
# you probably want to use ->do_mode_string(), which sends to users and servers.
#
sub handle_mode_string {
    my ($channel, $server, $source, $modestr, $force, $over_protocol) = @_;

    # extract the modes.
    my $changes = $server->cmodes_from_string($modestr, $over_protocol);

    # handle the modes.
    return $channel->handle_modes($source, $changes, $force, $over_protocol);

}

# returns a +modes string.
sub mode_string        { _mode_string(0, @_) }
sub mode_string_hidden { _mode_string(1, @_) }
sub _mode_string       {
    my ($show_hidden, $channel, $server) = @_;
    my (@modes, @params);
    my @set_modes = sort keys %{ $channel->{modes} };

    # "normal types" generally means the ones that show in MODES.
    # does not include lists, status, etc.
    my %normal_types = (
        0 => 1,                 # normal modes always incluided
        1 => 1,                 # parameter always included
        2 => 1,                 # parameter_set always included
        5 => $show_hidden       # key only if included showing hidden
    );

    # add all the modes for each of these types.
    foreach my $name (@set_modes) {
        next unless $normal_types{ $server->cmode_type($name) };

        push @modes, $server->cmode_letter($name);
        my $param = $channel->mode_parameter($name);
        push @params, $param if defined $param;
    }

    return '+'.join(' ', join('', @modes), @params);
}


my %zero_or_one = map { $_ => 1 } (0, 1, 2);    # zero or one parameters
my %exactly_one = map { $_ => 1 } (1, 2, 5);    # exactly one parameter

# includes ALL modes
#
# returns a string for users and a string for servers
# $no_status = all but status modes
#
sub mode_string_all {
    my ($channel, $server, $no_status) = @_;
    my (@modes, @user_params, @server_params);
    my @set_modes = sort keys %{ $channel->{modes} };


    foreach my $name (@set_modes) {
        my $letter = $server->cmode_letter($name);
        my $type   = $server->cmode_type($name);

        # if it takes 0 or 1 parameters, add 1 mode letter.
        push @modes, $letter if $zero_or_one{$type};

        # exactly one parameter; add it.
        if ($exactly_one{$type}) {
            push @user_params,   $channel->{modes}{$name}{parameter};
            push @server_params, $channel->{modes}{$name}{parameter};
        }

        # list modes. add each item.
        elsif ($type == 3) {
            foreach my $thing ($channel->list_elements($name)) {
                push @modes,         $letter;
                push @user_params,   $thing;
                push @server_params, $thing;
            }
        }

        # status modes. add each nick/uid.
        elsif ($type == 4 && !$no_status) {
            foreach my $user ($channel->list_elements($name)) {
                push @modes,         $letter;
                push @user_params,   $user->{nick};
                push @server_params, $user->{uid};
            }
        }

    }

    # make +modes params strings.
    my $user_string   = '+'.join(' ', join('', @modes), @user_params);
    my $server_string = '+'.join(' ', join('', @modes), @server_params);

    # returns both a user string and a server string.
    return ($user_string, $server_string);
}

# same mode_string except for status modes only.
sub mode_string_status {
    my ($channel, $server) = @_;
    my (@modes, @user_params, @server_params);
    my @set_modes = sort keys %{ $channel->{modes} };

    foreach my $name (@set_modes) {
        my $letter = $server->cmode_letter($name);
        next unless $server->cmode_type($name) == 4;

        foreach my $user ($channel->list_elements($name)) {
            push @modes,         $letter;
            push @user_params,   $user->{nick};
            push @server_params, $user->{uid};
        }
    }

    # make +modes params strings.
    my $user_string   = '+'.join(' ', join('', @modes), @user_params);
    my $server_string = '+'.join(' ', join('', @modes), @server_params);

    # returns both a user string and a server string.
    return ($user_string, $server_string);
}

# returns true only if the passed user is in
# the passed status list.
sub user_is {
    my ($channel, $user, $what) = @_;
    return 1 if $channel->list_has($what, $user);
    return;
}

# returns true value only if the passed user has status
# greater than voice (halfop, op, admin, owner)
sub user_has_basic_status {
    my ($channel, $user) = @_;
    return $channel->user_get_highest_level($user) >= -1;
}

# get the highest level of a user
# [letter, symbol, name]
sub user_get_highest_level {
    my ($channel, $user) = @_;
    return -inf if !$channel->has_user($user);
    return ($channel->user_get_levels($user))[0] // -inf;
}

# get all the levels of a user
sub user_get_levels {
    my ($channel, $user) = @_;
    return if !$channel->has_user($user);
    my @levels;
    foreach my $level (sort { $b <=> $a } keys %ircd::channel_mode_prefixes) {
        my ($letter, $symbol, $name) =
            ref_to_list($ircd::channel_mode_prefixes{$level});
        push @levels, $level if $channel->list_has($name, $user);
    }
    return @levels;
}

# fetch the topic or return undef if none.
sub topic {
    my $channel = shift;
    return $channel->{topic} if
      defined $channel->{topic}{topic} &&
      length $channel->{topic}{topic};
    delete $channel->{topic};
    return;
}

# destroy the channel maybe
sub destroy_maybe {
    my $channel = shift;

    # an event said not to destroy the channel.
    return if $channel->fire_event('can_destroy')->stopper;

    # there are still users in here!
    return if $channel->users;

    # delete the channel from the pool, purge events
    $pool->delete_channel($channel);
    $channel->delete_all_events();

    return 1;
}

sub id    { shift->{name}       }
sub name  { shift->{name}       }
sub users { @{ shift->{users} } }

############
### MINE ###
############

# send NAMES.
sub names {
    my ($channel, $user, $no_endof) = @_;
    $user->is_local or return;

    my $in_channel = $channel->has_user($user);
    my $prefixes   = $user->has_cap('multi-prefix') ? 'prefixes' : 'prefix';

    my @str;
    my $curr = 0;
    foreach my $usr ($channel->users) {

        # some extension said not to show this user.
        # the first user is the one being considered;
        # the second is the one which initiated the NAMES.
        next if $channel->fire_event(show_in_names => $usr, $user)->stopper;

        # if this user is invisible, do not show him unless the querier is in a common
        # channel or has the see_invisible flag.
        if ($usr->is_mode('invisible')) {
            next if !$in_channel && !$user->has_flag('see_invisible');
        }

        # add him.
        $str[$curr] .= $channel->$prefixes($usr).$usr->{nick}.q( );

        # if the current string is over 500 chars, start a new one.
        $curr++ if length $str[$curr] > 500;

    }

    # fire an event which allows modules to change the character.
    my $c = '=';
    $channel->fire_event(names_character => \$c);

    # send out the NAMREPLYs, if any. if no users matched, none will be sent.
    # then, send out ENDOFNAMES unless told not to by the caller.
    $user->numeric(RPL_NAMREPLY   => $c, $channel->name, $_) foreach @str;
    $user->numeric(RPL_ENDOFNAMES =>     $channel->name    ) unless $no_endof;

}

# send mode information.
sub modes {
    my ($channel, $user) = @_;
    my $modestr = $channel->mode_string($user->{server});
    $user->numeric(RPL_CHANNELMODEIS =>  $channel->name, $modestr);
    $user->numeric(RPL_CREATIONTIME  =>  $channel->name, $channel->{time});
}

# send a message to all the local members.
sub send_all {
    my ($channel, $what, $ignore) = @_;

    # $ignore can be either a user object or a codref
    # which returns true when the user should be ignored
    if ($ignore && !ref $ignore) {
        my $ignore_user = $ignore;
        $ignore = sub { shift() == $ignore_user };
    }

    foreach my $user ($channel->users) {

        # not local or ignored
        next unless $user->is_local;
        next if $ignore && $ignore->($user);

        $user->send($what);
    }
    return 1;
}

# send to members with a source.
sub sendfrom_all {
    my ($channel, $who, $what, $ignore) = @_;
    return send_all($channel, ":$who $what", $ignore);
}

# send to members with a capability.
# $alternative = send this if the user doesn't have the cap
sub sendfrom_all_cap {
    my ($channel, $who, $what, $alternative, $ignore, $cap) = @_;
    foreach my $user ($channel->users) {

        # not local or ignored
        next unless $user->is_local;
        next if $ignore && $ignore == $user;

        # sorry, don't have it
        if (!$user->has_cap($cap)) {
            $user->sendfrom($who, $alternative) if length $alternative;
            next;
        }

        $user->sendfrom($who, $what);
    }
    return 1;
}

# send a notice to all the local members.
sub notice_all {
    my ($channel, $what, $ignore) = @_;
    foreach my $user ($channel->users) {
        next unless $user->is_local;
        next if defined $ignore && $ignore == $user;
        $user->sendfrom($me->name, "NOTICE $$channel{name} :*** $what");
    }
    return 1;
}

# take the lower time of a channel and unset higher time stuff.
sub take_lower_time {
    my ($channel, $time, $ignore_modes) = @_;
    return $channel->{time} if $time >= $channel->{time};

    L("locally resetting $$channel{name} time to $time");
    my $amount = $channel->{time} - $time;
    $channel->set_time($time);

    # unset topic.
    if ($channel->topic) {
        $channel->sendfrom_all($me->{name}, "TOPIC $$channel{name} :");
        delete $channel->{topic};
    }

    # unset all channel modes.
    # hackery: use the server mode string to reset all modes.
    # note: we can't use do_mode_string() because it would send to other servers.
    # note: we don't do this for CUM cmd ($ignore_modes = 1) because it handles
    #       modes in a prettier manner.
    if (!$ignore_modes) {
        my ($u_str, $s_str)  = $channel->mode_string_all($me);
        substr($u_str, 0, 1) = substr($s_str, 0, 1) = '-';
        $channel->sendfrom_all($me->{name}, "MODE $$channel{name} $u_str");
        $channel->handle_mode_string($me, $me, $s_str, 1, 1);
    }

    notice_all($channel, "New channel time: ".scalar(localtime $time)." (set back $amount seconds)");
    return $channel->{time};
}

# returns the highest prefix a user has.
sub prefix {
    my ($channel, $user) = @_;
    my $level = $channel->user_get_highest_level($user);
    if (defined $level && $ircd::channel_mode_prefixes{$level}) {
        return $ircd::channel_mode_prefixes{$level}[1];
    }
    return q..;
}

# returns list of all prefixes a user has, greatest to smallest.
sub prefixes {
    my ($channel, $user) = @_;
    my $prefixes = '';
    foreach my $level (sort { $b <=> $a } keys %ircd::channel_mode_prefixes) {
        my ($letter, $symbol, $name) =
            ref_to_list($ircd::channel_mode_prefixes{$level});
        $prefixes .= $symbol if $channel->list_has($name, $user);
    }
    return $prefixes;
}

# handle named modes, tell our local users, and tell other servers.
sub do_modes { _do_modes(undef, @_) }

# same as ->do_modes() except it never sends to other servers.
sub do_modes_local { _do_modes(1, @_) }

# ->do_modes() and ->do_modes_local()
#
# See issue #101 for the planning of these methods.
#
#   $source             the source of the mode change
#   $modes              named modes in an arrayref as described in issue #101
#   $force              whether to ignore permissions
#   $over_protocol      specifies that the modes originated on incoming s2s
#   $organize           whether to alphabetize and put positive changes first
#
sub _do_modes {
    my $local_only = shift;
    my ($channel, $source, $modes, $force, $over_protocol, $organize) = @_;

    # handle the mode.
    # ($source, $modes, $force, $over_protocol) = @_;
    my $changes = $channel->handle_modes(
        $source, $modes, $force, $over_protocol
    ) or return;

    # tell the channel's users. this might be sent as multiple messages.
    #
    # ->strings...($modes, $over_protocol, $split, $organize, $skip_checks)
    # $over_protocol is false here because we want nicks rather than UIDs.
    # $split is true here because we want to send multiple messages to users.
    #
    foreach ($me->strings_from_cmodes($changes, undef, 1, $organize, 1)) {
        next unless length > 1;
        $channel->sendfrom_all($source->full, "MODE $$channel{name} $_");
    }

    # stop here if it's not a local user or this server.
    return if $local_only || !$source->is_local;

    # the source is our user or this server, so tell other servers.
    #
    # ->strings...($modes, $over_protocol, $split, $organize, $skip_checks)
    # $over_protocol is true here because we want UIDs rather than nicks.
    # $split is false because we are generating a single mode string.
    # currently each protocol implementation has to split it when necessary.
    #
    # cmode => ($source, $channel, $time, $perspective, $server_modestr)
    #
    my $server_str = $me->strings_from_cmodes($changes, 1, undef, $organize, 1);
    $pool->fire_command_all(cmode =>
        $source, $channel, $channel->{time},
        $me, $server_str
    );

    return 1;
}

# handle a mode string, tell our local users, and tell other servers.
sub do_mode_string { _do_mode_string(undef, @_) }

# same as ->do_mode_string() except it never sends to other servers.
sub do_mode_string_local { _do_mode_string(1, @_) }

sub _do_mode_string {
    my ($local_only, $channel, $perspective, $source, $modestr, $force, $protocol) = @_;

    # extract the modes.
    my $changes = $perspective->cmodes_from_string($modestr, $protocol);

    # do the modes.
    return _do_modes($local_only, $channel, $source, $changes, $force, $protocol);
}

# handle a privmsg. send it to our local users and other servers.
# FIXME: this is just really bad.
# it is necessary though to distinguish real PRIVMSGs from ones initiated by other
# commands and whatnot; for example ECHO uses this directly.
sub handle_privmsgnotice {
    my ($channel, $command, $source, $message, $dont_forward, $force) = @_;
    my $user   = $source->isa('user')   ? $source : undef;
    my $server = $source->isa('server') ? $source : undef;
    $command   = uc $command;

    # it's a user.
    if ($user && !$force) {
        my $lccommand = lc $command;

        # can_message, can_notice, can_privmsg.
        return if $user->fire_events_together(
            [  can_message     => $channel, $message, $lccommand ],
            [ "can_$lccommand" => $channel, $message           ]
        )->stopper;

    }

    # tell local users.
    # ignore the source as well as deaf users.
    $channel->sendfrom_all(
        $source->full,
        "$command $$channel{name} :$message",
        sub { $_[0] == $source || $_[0]->is_mode('deaf') }
    );

    # then tell other servers.
    my %sent;
    foreach my $usr ($channel->users) {
        last if $dont_forward;

        # local users already know.
        next if $usr->is_local;

        # deaf users don't care.
        # if a server has all-deaf users, it will never receive the message.
        next if $usr->is_mode('deaf');

        # the source user is reached through this user's server,
        # or the source is the server we know the user from.
        next if $user   && $usr->{location} == $user->{location};
        next if $server && $usr->{location}{sid} == $server->{sid};

        # already sent to this server.
        next if $sent{ $usr->{location} };

        $usr->{location}->fire_command(privmsgnotice => $command, $source, $channel, $message);
        $sent{ $usr->{location} } = 1;

    }

    # fire event.
    $channel->fire_event($command => $source, $message);

    return 1;
}

# ->do_join()
# see issue #76 for background information
#
# 1. joins a user to the channel with ->add().
# 2. sends JOIN message to local users in common channels.
# 3. fires the user_joined event.
#
# note that this method is permitted for both local and remote users.
# it DOES NOT send join messages to servers; it is up to the server
# protocol implementation to do so with ->forward().
#
# $allow_already = do not consider whether the user is already in the channel.
# this is useful for local channel creation.
#
sub do_join {
    my ($channel, $user, $allow_already) = @_;
    my $already = $channel->has_user($user);

    # add the user.
    return if $already && !$allow_already;
    $channel->add($user) unless $already;

    # for each user in the channel, send a JOIN message.
    my $act_name = $user->{account} ? $user->{account}{name} : '*';
    $channel->sendfrom_all_cap(
        $user->full,
        "JOIN $$channel{name} $act_name :$$user{real}",     # IRCv3.1
        "JOIN $$channel{name}",                             # RFC1459
        undef,
        'extended-join'
    );

    # tell the users who care whether this person is away.
    $channel->sendfrom_all_cap(
        $user->full,
        "AWAY :$$user{away}",   # IRCv3.1
        undef,                  # no alternative
        $user,                  # don't send to the user himself
        'away-notify'
    ) if $user->{away};

    # if local, send topic and names.
    if ($user->is_local) {
        $user->handle("TOPIC $$channel{name}") if $channel->topic;
        names($channel, $user);
    }

    # fire after join event.
    $channel->fire_event(user_joined => $user);

}

# ->attempt_local_join()
# see issue #76 for background information
#
# this is essentially a JOIN command handler - it checks that a local user can
# join a channel, deals with channel creation, set automodes, and more.
#
# this method CANNOT be used on remote users. note that this method MAY
# send out join and/or channel burst messages to servers.
#
# $new      = whether it's a new channel; this will deal with automodes
# $key      = provided channel key, if any. does nothing when $force
# $force    = do not check if the user is actually allowed to join
#
sub attempt_local_join {
    my ($channel, $user, $new, $key, $force) = @_;
    return unless $user->is_local;

    # if we're not forcing the join, check that the user is permitted to join.
    unless ($force) {

        # fire the event and delete the callbacks.
        my $event = $user->fire(can_join => $channel, $key);

        # event was stopped; can't join.
        if ($event->stopper) {
            $user->fire(join_failed => $channel, $event->stop, $event->stopper);
            return;
        }

    }

    # new channel. do automodes and whatnot.
    if ($new) {
        $channel->add($user); # early join
        my $str = conf('channels', 'automodes') || '';
        $str =~ s/\+user/$$user{uid}/g;

        # we're using ->handle_mode_string() because ->do_mode_string()
        # does only two other things:
        #
        # 1. sends the mode change to other servers
        # (we're doing that below with channel_burst)
        #
        # 2. sends the mode change to other users
        # (at this point, no one is in the new channel yet)
        #
        $channel->handle_mode_string($me, $me, $str, 1, 1);

    }

    # tell other servers
    if ($new) {
        $pool->fire_command_all(channel_burst => $channel, $me, $user);
    }
    else {
        $pool->fire_command_all(join => $user, $channel, $channel->{time});
    }

    # do the actual join. the $new means to allow the ->do_join() even though
    # the user might already be in there from the previous ->add().
    return $channel->do_join($user, $new);

}

# handle a part locally for both local and remote users.
sub do_part {
    my ($channel, $user, $reason, $quiet) = @_;

    # remove the user and tell the local channel users
    my $ureason = length $reason ? " :$reason" : '';
    $channel->sendfrom_all($user->full, "PART $$channel{name}$ureason");
    $channel->remove($user);

    # tell opers unless it's quiet
    notice(user_part =>
        $user->notice_info, $channel->name, $reason // 'no reason')
        unless $quiet;

    return 1;
}

# handle a kick. send it to local users.
sub user_get_kicked {
    my ($channel, $user, $source, $reason) = @_;

    # fallback reason to source.
    $reason //= $source->name;

    # tell the local users of the channel.
    $channel->sendfrom_all($source->full, "KICK $$channel{name} $$user{nick} :$reason");

    notice(user_kick =>
        $user->notice_info,
        $channel->name,
        $source->name,
        $reason
    ) if $source->isa('user');

    return $channel->remove_user($user);
}

$mod
