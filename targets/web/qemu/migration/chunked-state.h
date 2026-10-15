/* PowOS web: the incoming snapshot state streamed on demand (chunked-state.c). */
#ifndef QEMU_MIGRATION_CHUNKED_STATE_H
#define QEMU_MIGRATION_CHUNKED_STATE_H

#include "io/channel.h"

QIOChannel *chunked_state_open(const char *index, Error **errp);

#endif
