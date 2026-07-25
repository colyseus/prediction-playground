// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_GOALSTATE_H__
#define __SCHEMA_CODEGEN_GOALSTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "goal_player.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
    uint8_t denyRate;
} goal_state_t;

static const colyseus_field_t goal_state_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(goal_state_t, players), &goal_player_vtable, NULL, NULL},
    {1, "denyRate", COLYSEUS_FIELD_UINT8, "uint8", offsetof(goal_state_t, denyRate), NULL, NULL, NULL}
};

static goal_state_t* goal_state_create(void) {
    goal_state_t* instance = calloc(1, sizeof(goal_state_t));
    return instance;
}

static void goal_state_destroy(colyseus_schema_t* schema) {
    goal_state_t* instance = (goal_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t goal_state_vtable = {
    "GoalState",
    sizeof(goal_state_t),
    (colyseus_schema_t* (*)(void))goal_state_create,
    goal_state_destroy,
    goal_state_fields,
    2
};

#endif
