
package JdlBot::Build::Perl;

use strict;
use warnings;

use File::Find;
use Path::Class;
require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(loadTemplates loadStatic loadAssets checkConfigFile openBrowser);

sub loadFile {
 	my $path = $_[0];
 	my $file;
 	open( $file, '<', $path);
 	my $content = join( "", <$file> );
 	close($file);
 	return $content;
}

sub loadTemplates {
	my %templates = ();
	$templates{'base'} =
	  Text::Template->new( TYPE => 'FILE', SOURCE => 'base.html' );
	$templates{'config'} =
	  Text::Template->new( TYPE => 'FILE', SOURCE => 'config.html' );
	$templates{'status'} =
	  Text::Template->new( TYPE => 'FILE', SOURCE => 'status.html' );

	return %templates;
}

sub loadAssets {
	my %assets = ();
	find(sub {
		my $content = loadFile($_) if -f;
		my $mime;
		if ( $_ =~ /.js$/ ) {
			$mime = 'text/javascript';
		} elsif ( $_ =~ /.css$/ ) {
			$mime = 'text/css';
		} else {
			$mime = '';
		}
		$assets{"/".$File::Find::name} = sub {
		my ($httpd, $req) = @_;

		$req->respond({ content => [$mime, $content] });
		}
	}, 'assets/');
	
	
	return %assets;
}

sub loadStatic {
	my $static = {};
	my @staticFiles = (
		'filters.html',
		'feeds.html',
		'linktypes.html',
		'help.html',
		'history.html'
	);
	foreach my $file (@staticFiles) {
		$static->{$file} = loadFile($file);
	}

	return $static;
}

sub checkConfigFile {
	my $configdir;
	if ( $^O =~ /MSWin/ ) {
		$configdir = dir($ENV{'APPDATA'} , 'jdlbot');
		$configdir->mkpath();
	}	elsif ( $^O eq 'darwin' ) {
		$configdir = dir($ENV{'HOME'} , 'Library', 'jdlbot');
		$configdir->mkpath();
	} else {
		$configdir = dir($ENV{'HOME'} , '.jdlbot');
		$configdir->mkpath();
	}
	my $configfile = file( $configdir, 'config.sqlite');
	if ( -f $configfile ) {
		return $configfile->stringify();
	}
	elsif ( -f 'config.sqlite' ) {
			if ( file('config.sqlite')->copy_to($configfile) ) {
				return $configfile->stringify();
			}
	}
	return 0;
}

sub openBrowser {

	#Do nothing
	return 1;
}

1;
