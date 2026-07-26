// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.8
// 
#ifndef __SCHEMA_CODEGEN_BUMPSTATE_H__
#define __SCHEMA_CODEGEN_BUMPSTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "bump_player.h"
#include "bot.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
    colyseus_map_schema_t* bots;
} bump_state_t;

static const colyseus_field_t bump_state_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(bump_state_t, players), &bump_player_vtable, NULL},
    {1, "bots", COLYSEUS_FIELD_MAP, "map", offsetof(bump_state_t, bots), &bot_vtable, NULL}
};

static bump_state_t* bump_state_create(void) {
    bump_state_t* instance = calloc(1, sizeof(bump_state_t));
    return instance;
}

static void bump_state_destroy(colyseus_schema_t* schema) {
    bump_state_t* instance = (bump_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t bump_state_vtable = {
    "BumpState",
    sizeof(bump_state_t),
    (colyseus_schema_t* (*)(void))bump_state_create,
    bump_state_destroy,
    bump_state_fields,
    2
};

#endif
