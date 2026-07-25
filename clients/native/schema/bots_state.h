// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_BOTSSTATE_H__
#define __SCHEMA_CODEGEN_BOTSSTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "player.h"
#include "bot.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
    colyseus_map_schema_t* bots;
} bots_state_t;

static const colyseus_field_t bots_state_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(bots_state_t, players), &player_vtable, NULL, NULL},
    {1, "bots", COLYSEUS_FIELD_MAP, "map", offsetof(bots_state_t, bots), &bot_vtable, NULL, NULL}
};

static bots_state_t* bots_state_create(void) {
    bots_state_t* instance = calloc(1, sizeof(bots_state_t));
    return instance;
}

static void bots_state_destroy(colyseus_schema_t* schema) {
    bots_state_t* instance = (bots_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t bots_state_vtable = {
    "BotsState",
    sizeof(bots_state_t),
    (colyseus_schema_t* (*)(void))bots_state_create,
    bots_state_destroy,
    bots_state_fields,
    2
};

#endif
