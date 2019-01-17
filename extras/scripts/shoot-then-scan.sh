#! /bin/sh

# This script is a "shoot then scan" photo capture station.  gphoto2
# continuously captures photos from a tethered camera.  Whenever the barcode
# reader scans a barcode, it uploads the most recently captured photo to the
# server, identified by the barcode.
#

SELF="$0"
# readlink -f exists in linux (particularly RPi), but not e.g. Mac
[ -L "$SELF" ] && SELF=`readlink -f "$SELF"`
SELF_DIR=`dirname "$SELF"`
. "$SELF_DIR"/lib/photo-preamble.sh
. "$SELF_DIR"/lib/photo-functions.sh

killall_gvfs_volume_monitor

# The background task seems to continue running even after a control-C
# unless we clean it up. Next thing you know, your rpi's CPU is maxed out.
cleanup() {
    echo Cleanup "`basename $0`"
    killall "`basename $0`"
    exit 0
}
trap cleanup 2 3 6

CUR_DIR="`pwd`"
PHOTO_DIR="$CUR_DIR/photos-`date +%Y-%m-%d`"
mkdir "$PHOTO_DIR" >/dev/null 2>&1

rm uploads.log > /dev/null 2>&1
rm checkins.log > /dev/null 2>&1

BARCODE_SCANNER_DEV=/dev/input/by-id/usb-13ba_Barcode_Reader-event-kbd

# Depends on $PHOTO_DIR being defined.
loop_to_capture_tethered() {
    HOOK_SCRIPT="`mktemp`"
    cat <<EOF >"$HOOK_SCRIPT"
#! /bin/sh
if [ "\$ACTION" = "download" ] ; then
    # The file is already downloaded from the camera by the time 
    # this action comes
    >&2 echo Download action "\$ARGUMENT"
    ln -sf "\$ARGUMENT" "$CUR_DIR/last-photo.jpg"
    >&2 echo Link formed
    test -f /etc/derbynet.conf  && . /etc/derbynet.conf
    announce capture-ok &
else
    >&2 echo hook script action "\$ACTION"
fi
EOF
    chmod +x "$HOOK_SCRIPT"

    while true ; do
        echo Top of loop
        GPHOTO2_OK=0
        # stdout gets flooded with a ton of messages like
        #     UNKNOWN PTP Property d1d3 changed
        # hence the /dev/null.
        gphoto2 --quiet --hook-script "$HOOK_SCRIPT" \
                --filename "$PHOTO_DIR/photo-%H%M%S-%n.%C" \
                --capture-tethered \
                >/dev/null && GPHOTO2_OK=1
        if [ $GPHOTO2_OK -eq 0 ] ; then
            announce no-camera
            sleep 5s
        fi
        sleep 1s
    done
}

do_login

check_scanner

announce idle

# Run the capture-tethered loop on a fork so camera capturing and photo uploads
# don't interfere with each other.
loop_to_capture_tethered &

while true ; do
    BARCODE=`barcode $BARCODE_SCANNER_DEV`
    echo Scanned $BARCODE
    CAR_NO=`echo $BARCODE | grep -e "^PWD" | sed -e "s/^PWD//"`

    if [ "$BARCODE" = "QUITQUITQUIT" ] ; then
        announce terminating
        sudo shutdown -h now
    elif [ "$BARCODE" = "PWDspeedtest" ] ; then
        upload_speed_test
    elif [ ! -L last-photo.jpg -o ! -e "`readlink last-photo.jpg`" ] ; then
        # We'd like something more specific
        announce upload-failed
    elif [ "$CAR_NO" ] ; then

        LINK="`readlink last-photo.jpg`"
        DIRNAME="`dirname "$LINK"`"
        FILENAME=Car$CAR_NO.jpg
        I=0
        while [ "$LINK" != "$DIRNAME/$FILENAME" -a -e "$DIRNAME/$FILENAME" ] ; do
            I=`expr $I + 1`
            FILENAME=Car${CAR_NO}_$I.jpg
        done

        if [ "$LINK" != "$DIRNAME/$FILENAME" ] ; then
            mv "$LINK" "$DIRNAME/$FILENAME"
            ln -sf "$DIRNAME/$FILENAME" last-photo.jpg
        fi

        maybe_check_in_racer

        upload_photo "$DIRNAME/$FILENAME"

    else
        echo Rejecting scanned barcode $BARCODE
        announce unrecognized-barcode
    fi
done
