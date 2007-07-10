# -*- mode: cperl; c-basic-offset: 8; indent-tabs-mode: nil; -*-

=head1 COPYRIGHT

 # ***** BEGIN LICENSE BLOCK *****
 # Version: MPL 1.1
 #
 # The contents of this file are subject to the Mozilla Public License
 # Version 1.1 (the "License"); you may not use this file except in
 # compliance with the License. You may obtain a copy of the License
 # at http://www.mozilla.org/MPL/
 #
 # Software distributed under the License is distributed on an "AS IS"
 # basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 # the License for the specific language governing rights and
 # limitations under the License.
 #
 # The Original Code is Litmus.
 #
 # The Initial Developer of the Original Code is
 # the Mozilla Corporation.
 # Portions created by the Initial Developer are Copyright (C) 2006
 # the Initial Developer. All Rights Reserved.
 #
 # Contributor(s):
 #   Chris Cooper <ccooper@deadsquid.com>
 #   Zach Lipton <zach@zachlipton.com>
 #
 # ***** END LICENSE BLOCK *****

=cut

package Litmus::DBI;

require Apache::DBI;
use strict;
use warnings;
use Litmus::Config;
use Litmus::Memoize;

use base 'Class::DBI::mysql';

use constant MP2 => ( exists $ENV{MOD_PERL_API_VERSION} and 
                        $ENV{MOD_PERL_API_VERSION} >= 2 ); 
use constant MP1 => ( exists $ENV{MOD_PERL} and 
                        ! exists $ENV{MOD_PERL_API_VERSION});  

our $dsn = "dbi:mysql:database=$Litmus::Config::db_name;host=$Litmus::Config::db_host;port=3306";

our %column_aliases;

Litmus::DBI->autoupdate(1);
                         
# In some cases, we have column names that make sense from a database perspective
# (i.e. subgroup_id), but that don't make sense from a class/object perspective 
# (where subgroup would be more appropriate). To handle this, we allow for 
# Litmus::DBI's subclasses to set column aliases with the column_alias() sub. 
# Takes the database column name and the alias name. 
sub column_alias {
    my ($self, $db_name, $alias_name) = @_;
    
    $column_aliases{$alias_name} = $db_name;
}

# here's where the actual work happens. We consult our alias list 
# (as created by calls to column_alias()) and substitute the 
# database column if we find a match
memoize('find_column', persist=>1);
sub find_column {
    my $self = shift;
    my $wanted = shift;
    
    if (ref $self) {
        $wanted =~ s/^.*::(\w+)$/$1/;
    }
    if ($column_aliases{$wanted}) {
        return $column_aliases{$wanted};
    } else {
        # not an alias, so we use the normal 
        # find_column() from Class::DBI
        $self->SUPER::find_column($wanted);
    }
}

sub AUTOLOAD {
    my $self = shift;
    my @args = @_;
    my $name = our $AUTOLOAD;
    
    my $col = $self->find_column($name);
    if (!$col) {
        lastDitchError("tried to call Litmus::DBI method $name which does not exist");
    }
    
    return $self->$col(@args);
}

# DBI error handler for SQL errors:        
sub _croak {
	my ($self, $message, %info) = @_;
	lastDitchError($message);
	return;
}

sub lastDitchError($) {
    my $message = shift;
    print "Error - Litmus has suffered a serious fatal internal error - $message";
    exit;
}

# Get Class::DBI's default dbh options
my $db_options = { __PACKAGE__->_default_attributes };

__PACKAGE__->_remember_handle('Main'); # so dbi_commit works

# override default to avoid using Ima::DBI closure for mod_perl compatibility
sub db_Main {
   my $dbh;
   my $request;
   if (MP1) {
       $request = Apache->request();
   } elsif (MP2) {
       $request = Apache2::RequestUtil::request();
   }
   if ( $ENV{'MOD_PERL'} and defined $request ) {
	   $dbh = $request->pnotes('dbh');
   }
   if ( !$dbh ) {
	   $dbh = DBI->connect_cached(
		   $dsn,  $Litmus::Config::db_user,
		   $Litmus::Config::db_pass, $db_options
	   );
	   if ( $ENV{'MOD_PERL'} and defined $request ) {
		   $request->pnotes( 'dbh', $dbh );
	   }
   }
   return $dbh;
}

# hack around a bug where auto_increment columns don't work properly unless 
# the auto_increment key is explicitly set to null in insert statements:
sub _auto_increment_value {
	my $self = shift;
	my $dbh  = $self->db_Main;
	my $id;
	eval { 
		my $sth = $dbh->prepare("SELECT LAST_INSERT_ID()");
		$sth->execute();
		my @data = $sth->fetchrow_array();
		$id = $data[0];
	} or return $self->SUPER::_auto_increment_value();
	if (! defined $id) { return $self->SUPER::_auto_increment_value() }
	return $id;
}

1;
