// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_PROJECTILESTATE_H__
#define __SCHEMA_CODEGEN_PROJECTILESTATE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

#include "player.h"
#include "projectile.h"

typedef struct {
    colyseus_schema_t __base;
    colyseus_map_schema_t* players;
    colyseus_map_schema_t* projectiles;
} projectile_state_t;

static const colyseus_field_t projectile_state_fields[] = {
    {0, "players", COLYSEUS_FIELD_MAP, "map", offsetof(projectile_state_t, players), &player_vtable, NULL, NULL},
    {1, "projectiles", COLYSEUS_FIELD_MAP, "map", offsetof(projectile_state_t, projectiles), &projectile_vtable, NULL, NULL}
};

static projectile_state_t* projectile_state_create(void) {
    projectile_state_t* instance = calloc(1, sizeof(projectile_state_t));
    return instance;
}

static void projectile_state_destroy(colyseus_schema_t* schema) {
    projectile_state_t* instance = (projectile_state_t*)schema;
    free(instance);
}

static const colyseus_schema_vtable_t projectile_state_vtable = {
    "ProjectileState",
    sizeof(projectile_state_t),
    (colyseus_schema_t* (*)(void))projectile_state_create,
    projectile_state_destroy,
    projectile_state_fields,
    2
};

#endif
