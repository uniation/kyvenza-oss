No patches are applied to QEMU.

Kyvenza builds the upstream qemu-11.1.0 release unmodified; every difference
from a stock build comes from the configure flags in build_qemu.sh. If a patch
is ever added, it will appear in this directory and build_qemu.sh will apply it
automatically.
