// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_RANGESTATE_H__
#define __SCHEMA_CODEGEN_RANGESTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "range_player.h"
#include "bot.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
    colyseus_map_schema_t* bots;
    bool lagComp;
    uint32_t salt;
} range_state_t;

static const colyseus_field_t range_state_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(range_state_t, players), &range_player_vtable, NULL, NULL},
    {1, "bots", COLYSEUS_FIELD_MAP, "map", offsetof(range_state_t, bots), &bot_vtable, NULL, NULL},
    {2, "lagComp", COLYSEUS_FIELD_BOOLEAN, "boolean", offsetof(range_state_t, lagComp), NULL, NULL, NULL},
    {3, "salt", COLYSEUS_FIELD_UINT32, "uint32", offsetof(range_state_t, salt), NULL, NULL, NULL}
};

static range_state_t* range_state_create(void) {
    range_state_t* instance = calloc(1, sizeof(range_state_t));
    return instance;
}

static void range_state_destroy(colyseus_schema_t* schema) {
    range_state_t* instance = (range_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t range_state_vtable = {
    "RangeState",
    sizeof(range_state_t),
    (colyseus_schema_t* (*)(void))range_state_create,
    range_state_destroy,
    range_state_fields,
    4
};

#endif
