# Charge NowPlayingBridge.dylib dans /usr/bin/perl (binaire signé Apple,
# donc autorisé par MediaRemote) et lance sa boucle.
# Usage : /usr/bin/perl bridge.pl /chemin/absolu/NowPlayingBridge.dylib
use strict;
use warnings;
use DynaLoader;

my $path = shift @ARGV or die "chemin du dylib manquant\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die DynaLoader::dl_error();
my $run = DynaLoader::dl_find_symbol($lib, "island_bridge_run") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::run", $run);
run();
