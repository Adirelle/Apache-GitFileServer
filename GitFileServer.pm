package Apache::GitFileServer;

=head1 LICENSE

Apache::GitFileServer

(c) 2013 Adirelle <adirelle@gmail.com>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut

use strict;
use warnings FATAL => 'all';
no warnings 'redefine';

use Apache2::RequestRec ();
use Apache2::RequestIO ();
use Apache2::ServerRec ();
use Apache2::ServerUtil ();
use Apache2::Module ();
use Apache2::CmdParms ();
use Apache2::Const qw(:common :override :cmd_how);
use APR::Table ();

use System::Sub qw(git);
use File::MimeInfo;

my @directives = (
	{
		name         => 'GitRepositoryRoot',
		req_override => ACCESS_CONF,
		args_how     => TAKE1,
		errmsg       => 'Path to the directory containing the repositories to serve.',
	},
	{
		name         => 'GitRepositoryDirSuffix',
		req_override => ACCESS_CONF,
		args_how     => TAKE1,
		errmsg       => 'String to append to the passed repository name to get the actual name.',
		func         => __PACKAGE__.'::set_config',
		cmd_data     => 'DirSuffix',
	},
	{
		name         => 'GitDefaultBranch',
		req_override => ACCESS_CONF,
		args_how     => TAKE1,
		errmsg       => 'The default branch to redirect to.',
		func         => __PACKAGE__.'::set_config',
		cmd_data     => 'DefaultBranch',
	},
	{
		name         => 'GitDefaultIndex',
		req_override => ACCESS_CONF,
		args_how     => TAKE1,
		errmsg       => 'The file to look for at the root.',
		func         => __PACKAGE__.'::set_config',
		cmd_data     => 'DefaultIndex',
	},
);

sub DIR_CREATE {
	my ($class, $parms) = @_;
	return bless {
		Root          => '/var/lib/git',
		DirSuffix     => '-pages',
		DefaultBranch => 'master',
		DefaultIndex  => 'index.html',
	}, $class;
}

sub strip_trailing_slash {
	(my $v = shift) =~ s@/$@@;
	return $v;
}

sub GitRepositoryRoot {
	my($cfg, $parms, $arg) = @_;
	die "GitRepositoryRoot: path not exist or is not a readable directory: $arg\0" unless -e $arg && -d $arg && -r $arg;
	$cfg->{Root} = strip_trailing_slash($arg);
}

sub set_config {
	my($cfg, $parms, $arg) = @_;
	$cfg->{$parms->info} = $arg || '';
}

Apache2::Module::add(__PACKAGE__, \@directives);

# return module configuration for current directory
sub get_config {
	my $r = shift;
	return Apache2::Module::get_config(__PACKAGE__, $r->server, $r->per_dir_config);
}

sub handler {
	my $r = shift;

	# Only accep GET and HEAD requests
	return 405 unless $r->method eq 'HEAD' or $r->method eq 'GET';

	my($dummy, $name, $revision, $path) = split /\//, $r->path_info, 4;

	# A repository name is required
	unless($name) {
		$r->log_reason("repository name required");
		return NOT_FOUND;
	}

	# Calculate the repository path and check if it exists and is readable.
	my $cfg = get_config($r);
	my $git_dir = $cfg->{Root}.'/'.$name.$cfg->{DirSuffix};
	unless(-d $git_dir) {
		$r->log_reason("repository does not exist");
		return NOT_FOUND;
	}
	unless(-r $git_dir) {
		$r->log_reason("repository is not readable");
		return NOT_FOUND;
	}

	# Redirect to master branch and/or index.html
	my $redirect = '';
	$redirect .= '/'.$cfg->{DefaultBranch} unless $revision;
	$redirect .= '/'.$cfg->{DefaultIndex} unless $path;
	if($redirect) {
		$r->headers_out->set(Location => strip_trailing_slash($r->uri).$redirect);
		return REDIRECT;
	}

	# Resolve the revision:path to a blob hash
	my $data = git('--git-dir' => $git_dir, 'cat-file', '--batch-check', \($revision.":".$path));
	my($hash, $type, $size) = split / /, $data;
	
	if($type eq "missing") {
		$r->log_reason("object does not exist");
		return NOT_FOUND;
	}
	unless($type eq "blob") {
		$r->log_reason("access to $type denied");
		return FORBIDDEN;
	}

	$r->headers_out->set(ETag => $hash);
	$r->content_type(mimetype($path) || 'application/octet-stream');

	if(my $known = $r->headers_in->{'If-None-Match'}) {
		return 304 if $known =~ /\b\Q$hash\E\b/;
	}

	if($r->method eq 'GET') {
		$r->headers_out->set('Content-Length' => $size);
		eval {
			local $/ = undef;
			git(
				'--git-dir' => $git_dir,
				'cat-file', $type, $hash,
				sub { $r->write($_[0]); }
			);
		};
		$r->rflush;
	}
	
	return OK;
}

1;
