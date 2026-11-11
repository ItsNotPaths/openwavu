// The online screens: the lobby list, and the lobby with its seats, stage, watchers and the host's settings.
#ifndef T6_ONLINE_H
#define T6_ONLINE_H

#include <stdint.h>
#include "catalog.h"
#include "openwavu.h"

enum Online_Step {
    ONLINE_STAY,
    ONLINE_OFFLINE,  // left the network
    ONLINE_HOST,     // hosting: pick the stage first
    ONLINE_JOINED,
    ONLINE_PICK,     // a seated player picks a fighter, which readies
    ONLINE_LEFT,     // out of the lobby
};

enum Online_Step lobbies_step(const OwHostView *view, uint32_t pressed);
void lobbies_draw(const OwHostView *view);
enum Online_Step lobby_step(const OwHostView *view, const T6Catalog *catalog, uint32_t pressed);
void lobby_draw(const OwHostView *view, const T6Catalog *catalog);

#endif
