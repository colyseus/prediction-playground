// 
// THIS FILE HAS BEEN GENERATED AUTOMATICALLY
// DO NOT CHANGE IT MANUALLY UNLESS YOU KNOW WHAT YOU'RE DOING
// 
// GENERATED USING @colyseus/schema 5.0.11
// 
#ifndef __SCHEMA_CODEGEN_PROJECTILE_H__
#define __SCHEMA_CODEGEN_PROJECTILE_H__ 1

#include "colyseus/schema/types.h"
#include "colyseus/schema/collections.h"
#include <stdlib.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    colyseus_schema_t __base;
    double x;
    double y;
    double vx;
    double vy;
    char* owner;
    double bornMs;
} projectile_t;

static const colyseus_field_t projectile_fields[] = {
    {0, "x", COLYSEUS_FIELD_NUMBER, "number", offsetof(projectile_t, x), NULL, NULL, NULL},
    {1, "y", COLYSEUS_FIELD_NUMBER, "number", offsetof(projectile_t, y), NULL, NULL, NULL},
    {2, "vx", COLYSEUS_FIELD_NUMBER, "number", offsetof(projectile_t, vx), NULL, NULL, NULL},
    {3, "vy", COLYSEUS_FIELD_NUMBER, "number", offsetof(projectile_t, vy), NULL, NULL, NULL},
    {4, "owner", COLYSEUS_FIELD_STRING, "string", offsetof(projectile_t, owner), NULL, NULL, NULL},
    {5, "bornMs", COLYSEUS_FIELD_NUMBER, "number", offsetof(projectile_t, bornMs), NULL, NULL, NULL}
};

static projectile_t* projectile_create(void) {
    projectile_t* instance = calloc(1, sizeof(projectile_t));
    return instance;
}

static void projectile_destroy(colyseus_schema_t* schema) {
    projectile_t* instance = (projectile_t*)schema;
    if (instance->owner) free(instance->owner);
    free(instance);
}

static const colyseus_schema_vtable_t projectile_vtable = {
    "Projectile",
    sizeof(projectile_t),
    (colyseus_schema_t* (*)(void))projectile_create,
    projectile_destroy,
    projectile_fields,
    6
};

#endif
