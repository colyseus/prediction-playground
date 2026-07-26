// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.8
// 
#ifndef __SCHEMA_CODEGEN_HOCKEYSTATE_H__
#define __SCHEMA_CODEGEN_HOCKEYSTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "player.h"
#include "puck.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
    puck_t* puck;
    bool botEnabled;
} hockey_state_t;

static const colyseus_field_t hockey_state_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(hockey_state_t, players), &player_vtable, NULL},
    {1, "puck", COLYSEUS_FIELD_REF, "ref", offsetof(hockey_state_t, puck), &puck_vtable, NULL},
    {2, "botEnabled", COLYSEUS_FIELD_BOOLEAN, "boolean", offsetof(hockey_state_t, botEnabled), NULL, NULL}
};

static hockey_state_t* hockey_state_create(void) {
    hockey_state_t* instance = calloc(1, sizeof(hockey_state_t));
    return instance;
}

static void hockey_state_destroy(colyseus_schema_t* schema) {
    hockey_state_t* instance = (hockey_state_t*)schema;
    if (instance->puck) puck_destroy((colyseus_schema_t*)instance->puck);
    free(instance);
}

static const colyseus_schema_vtable_t hockey_state_vtable = {
    "HockeyState",
    sizeof(hockey_state_t),
    (colyseus_schema_t* (*)(void))hockey_state_create,
    hockey_state_destroy,
    hockey_state_fields,
    3
};

#endif
