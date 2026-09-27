#!/bin/busybox sh
BUSYBOX=/bin/busybox

${BUSYBOX} mount -t proc proc /proc
${BUSYBOX} mount -t sysfs sysfs /sys

echo 'Duriel has initialized.'
exec ${BUSYBOX} sh
