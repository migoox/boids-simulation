#include "boids_cuda.hpp"
#include "cuda_runtime.h"

#include <thrust/sort.h>
#include <thrust/execution_policy.h>
#include <iostream>
#include <curand_kernel.h>
#include <cuda_gl_interop.h>
#define BLOCK_SIZE 256

using namespace boids::cuda_gpu;
using namespace boids;

__device__ curandState state[SimulationParameters::MAX_BOID_COUNT];

__device__ CellId flatten_coords(const SimulationParameters *sim_params, CellCoords coords) {
    CellCoord grid_size_x = std::ceil(sim_params->aquarium_size.x / sim_params->distance);
    CellCoord grid_size_y = std::ceil(sim_params->aquarium_size.y / sim_params->distance);

    return coords.x + coords.y * grid_size_x + coords.z * grid_size_x * grid_size_y;
}

__device__ CellId flatten_coords(const SimulationParameters *sim_params, CellCoord x, CellCoord y, CellCoord z) {
    CellCoord grid_size_x = std::ceil(sim_params->aquarium_size.x / sim_params->distance);
    CellCoord grid_size_y = std::ceil(sim_params->aquarium_size.y / sim_params->distance);

    return x + y * grid_size_x + z * grid_size_x * grid_size_y;
}

__device__ CellCoords get_cell_cords(const SimulationParameters *sim_params, const glm::vec4& position) {
    return CellCoords {
            static_cast<CellCoord>((position.x + sim_params->aquarium_size.x / 2.f) / sim_params->distance),
            static_cast<CellCoord>((position.y + sim_params->aquarium_size.y / 2.f) / sim_params->distance),
            static_cast<CellCoord>((position.z + sim_params->aquarium_size.z / 2.f) / sim_params->distance)
    };
}

__device__ CellId get_flat_cell_id(
        const SimulationParameters *sim_params,
        const glm::vec4& position
) {
    return flatten_coords(
            sim_params,
            get_cell_cords(sim_params, position)
    );
}

__device__ void update_orientation(
        glm::vec4 *forward,
        glm::vec4 *up,
        glm::vec4 *right,
        glm::vec3 *velocity,
        BoidId b_id
) {
    // Update orientation
    forward[b_id] = glm::vec4(glm::normalize(velocity[b_id]), 0.f);
    right[b_id] = glm::vec4(glm::normalize(
            glm::cross(glm::vec3(up[b_id]),glm::vec3(forward[b_id]))
    ), 0.f);

    up[b_id] = glm::vec4(glm::normalize(
            glm::cross(glm::vec3(forward[b_id]), glm::vec3(right[b_id]))
    ), 0.f);

}

__device__ void update_pos_vel(
        const SimulationParameters *params,
        const glm::vec3* obstacle_position,
        const float* obstacle_radius,
        const int obstacle_count,
        const BoidId b_id,
        glm::vec4 *position,
        glm::vec4 *position_old,
        glm::vec3 *velocity,
        glm::vec3 *velocity_old,
        glm::vec3 acceleration,
        glm::vec4 *forward,
        glm::vec4 *up,
        glm::vec4 *right,
        float dt
) {
    float wall = 4.f;
    float wall_acc = 15.f;

    // Update walls
    if (position_old[b_id].x > params->aquarium_size.x / 2.f - wall) {
        auto intensity = std::abs((params->aquarium_size.x / 2.f - wall - position_old[b_id].x) / wall);
        acceleration += intensity * glm::vec3(-wall_acc, 0.f, 0.f);
    } else if (position_old[b_id].x < -params->aquarium_size.x / 2.f + wall) {
        auto intensity = std::abs((-params->aquarium_size.x / 2.f + wall - position_old[b_id].x) / wall);
        acceleration += intensity * glm::vec3(wall_acc, 0.f, 0.f);
    }

    if (position_old[b_id].y > params->aquarium_size.y / 2.f - wall) {
        auto intensity = std::abs((params->aquarium_size.y / 2.f - wall - position_old[b_id].y) / wall);
        acceleration += intensity * glm::vec3(0.f, -wall_acc, 0.f);
    } else if (position_old[b_id].y < -params->aquarium_size.y / 2.f + wall) {
        auto intensity = std::abs((-params->aquarium_size.y / 2.f + wall - position_old[b_id].y) / wall);
        acceleration += intensity * glm::vec3(0.f, wall_acc, 0.f);
    }

    if (position_old[b_id].z > params->aquarium_size.z / 2.f - wall) {
        auto intensity = std::abs((params->aquarium_size.z / 2.f - wall - position_old[b_id].z) / wall);
        acceleration += intensity * glm::vec3(0.f, 0.f, -wall_acc);
    } else if (position_old[b_id].z < -params->aquarium_size.z / 2.f + wall) {
        auto intensity = std::abs((-params->aquarium_size.z / 2.f + wall - position_old[b_id].z) / wall);
        acceleration += intensity * glm::vec3(0.f, 0.f, wall_acc);
    }

    // Update obstacles
    for (int i = 0; i < obstacle_count; ++i) {
        float dist = glm::distance(obstacle_position[i], glm::vec3(position_old[b_id]));

        if (dist > 1.4f * obstacle_radius[i]) {
            continue;
        }

        glm::vec3 e = obstacle_position[i] - glm::vec3(position_old[b_id]);
        glm::vec3 d = glm::normalize(velocity_old[b_id]);
        float de_dot = glm::dot(d, e);
        if (de_dot < 0.f) {
            continue;
        }
        glm::vec3 p = glm::vec3(position_old[b_id]) + d * de_dot;
        acceleration += glm::normalize(p - obstacle_position[i]) * 12.f;
    }

    velocity[b_id] = velocity_old[b_id] + acceleration * dt;

    if (glm::length(velocity[b_id]) > params->max_speed) {
        velocity[b_id] = glm::normalize(velocity[b_id]) * params->max_speed;
    } else if (glm::length(velocity[b_id]) < params->min_speed){
        velocity[b_id] = glm::normalize(velocity[b_id]) * params->min_speed;
    }

    position[b_id] = position_old[b_id] + glm::vec4(velocity[b_id] * dt, 0.f);

    // Update orientation
    update_orientation(forward, up, right, velocity, b_id);
}

__device__ void update_pos_vel_shared(
        const SimulationParameters *params,
        const glm::vec3* obstacle_position,
        const float* obstacle_radius,
        const int obstacle_count,
        const BoidId b_id,
        const int tid,
        glm::vec4 *position,
        glm::vec4 *position_old,
        glm::vec3 *velocity,
        glm::vec3 *velocity_old,
        glm::vec3 acceleration,
        glm::vec4 *forward,
        glm::vec4 *up,
        glm::vec4 *right,
        float dt
) {
    float wall = 4.f;
    float wall_acc = 15.f;

    // Update walls
    if (position_old[tid].x > params->aquarium_size.x / 2.f - wall) {
        auto intensity = std::abs((params->aquarium_size.x / 2.f - wall - position_old[tid].x) / wall);
        acceleration += intensity * glm::vec3(-wall_acc, 0.f, 0.f);
    } else if (position_old[tid].x < -params->aquarium_size.x / 2.f + wall) {
        auto intensity = std::abs((-params->aquarium_size.x / 2.f + wall - position_old[tid].x) / wall);
        acceleration += intensity * glm::vec3(wall_acc, 0.f, 0.f);
    }

    if (position_old[tid].y > params->aquarium_size.y / 2.f - wall) {
        auto intensity = std::abs((params->aquarium_size.y / 2.f - wall - position_old[tid].y) / wall);
        acceleration += intensity * glm::vec3(0.f, -wall_acc, 0.f);
    } else if (position_old[tid].y < -params->aquarium_size.y / 2.f + wall) {
        auto intensity = std::abs((-params->aquarium_size.y / 2.f + wall - position_old[tid].y) / wall);
        acceleration += intensity * glm::vec3(0.f, wall_acc, 0.f);
    }

    if (position_old[tid].z > params->aquarium_size.z / 2.f - wall) {
        auto intensity = std::abs((params->aquarium_size.z / 2.f - wall - position_old[tid].z) / wall);
        acceleration += intensity * glm::vec3(0.f, 0.f, -wall_acc);
    } else if (position_old[tid].z < -params->aquarium_size.z / 2.f + wall) {
        auto intensity = std::abs((-params->aquarium_size.z / 2.f + wall - position_old[tid].z) / wall);
        acceleration += intensity * glm::vec3(0.f, 0.f, wall_acc);
    }

    // Update obstacles
    for (int i = 0; i < obstacle_count; ++i) {
        float dist = glm::distance(obstacle_position[i], glm::vec3(position_old[tid]));

        if (dist > 1.4f * obstacle_radius[i]) {
            continue;
        }

        glm::vec3 e = obstacle_position[i] - glm::vec3(position_old[tid]);
        glm::vec3 d = glm::normalize(velocity_old[tid]);
        float de_dot = glm::dot(d, e);
        if (de_dot < 0.f) {
            continue;
        }
        glm::vec3 p = glm::vec3(position_old[tid]) + d * de_dot;
        acceleration += glm::normalize(p - obstacle_position[i]) * 12.f;
    }

    velocity[b_id] = velocity_old[tid] + acceleration * dt;

    if (glm::length(velocity[b_id]) > params->max_speed) {
        velocity[b_id] = glm::normalize(velocity[b_id]) * params->max_speed;
    } else if (glm::length(velocity[b_id]) < params->min_speed){
        velocity[b_id] = glm::normalize(velocity[b_id]) * params->min_speed;
    }

    position[b_id] = position_old[tid] + glm::vec4(velocity[b_id] * dt, 0.f);

    // Update orientation
    update_orientation(forward, up, right, velocity, b_id);
}

__global__ void setup_curand(size_t max_boid_count) {
    int id = threadIdx.x + blockIdx.x * blockDim.x;
    if (id >= max_boid_count) {
        return;
    }

    curand_init(1234, id, 0, &state[id]);
}


__global__ void ker_find_cell_ids(const boids::SimulationParameters *params, BoidId *boid_id, CellId *cell_id, glm::vec4 *position_old) {
    BoidId b_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (b_id >= params->boids_count) return;

    boid_id[b_id] = b_id;
    cell_id[b_id] = get_flat_cell_id(params, position_old[b_id]);
}

__global__ void ker_find_starts(CellId *cell_id, int *cell_start, int *cell_end, size_t boids_count) {
    int k = blockIdx.x * blockDim.x + threadIdx.x;

    if (k >= boids_count)  {
        return;
    }

    // TODO: do it better...
    if (k == 0) {
        cell_start[cell_id[0]] = 0;
    }

    if (k < boids_count - 1) {
        if (cell_id[k] != cell_id[k + 1]) {
            cell_start[cell_id[k + 1]] = k + 1;
            cell_end[cell_id[k]] = k + 1;
        }
    } else {
        if (k == boids_count - 1) {
            cell_end[cell_id[k]] = k + 1;
        }
    }
}


__global__ void ker_clear_starts(CellId *cell_id, int *cell_start, int *cell_end, size_t boids_count) {
    int k = blockIdx.x * blockDim.x + threadIdx.x;
    if (k >= boids_count) {
        return;
    }

    cell_start[cell_id[k]] = 0;
    cell_end[cell_id[k]] = 0;
}

__global__ void ker_update_simulation_naive(
        const SimulationParameters *params,
        const glm::vec3* obstacle_position,
        const float* obstacle_radius,
        const int obstacle_count,
        glm::vec4 *position,
        glm::vec4 *position_old,
        glm::vec3 *velocity,
        glm::vec3 *velocity_old,
        glm::vec4 *forward,
        glm::vec4 *up,
        glm::vec4 *right,
        float dt
) {
    BoidId b_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (b_id >= params->boids_count) return;

    glm::vec3 acceleration(0.f);

    glm::vec3 separation(0.);
    glm::vec3 avg_vel(0.);
    glm::vec3 avg_pos(0.);
    uint32_t neighbors_count = 0;

    for (BoidId other_id = 0; other_id < params->boids_count; ++other_id) {
        if (other_id == b_id) {
            continue;
        }

        auto distance2 = glm::dot(position_old[b_id] - position_old[other_id], position_old[b_id] - position_old[other_id]);
        if (distance2 > params->distance * params->distance) {
            continue;
        }

        separation += glm::vec3(glm::normalize(position_old[b_id] - position_old[other_id]) / distance2);
        avg_vel += velocity_old[other_id];
        avg_pos += glm::vec3(position_old[other_id]);

        ++neighbors_count;
    }

    if (neighbors_count > 0) {
        avg_vel /= float(neighbors_count);
        avg_pos /= float(neighbors_count);

        // Final acceleration of the current boid
        acceleration =
                params->separation * separation +
                params->alignment * (avg_vel - velocity_old[b_id]) +
                params->cohesion * (avg_pos - glm::vec3(position_old[b_id]));
    }

    // Add noise
    curandState local_state = state[b_id];
    float x = curand_uniform(&local_state);
    float y = curand_uniform(&local_state);
    float z = curand_uniform(&local_state);
    state[b_id] = local_state;
    acceleration += glm::normalize(glm::vec3(2.f * (x - 0.5f), 2.f * (y - 0.5f), 2.f * (z - 0.5f))) * params->noise;

    // Update pos and vel
    update_pos_vel(
            params,
            obstacle_position,
            obstacle_radius,
            obstacle_count,
            b_id,
            position,
            position_old,
            velocity,
            velocity_old,
            acceleration,
            forward,
            up,
            right,
            dt
    );
}

__global__ void ker_update_simulation_with_sort0(
        const SimulationParameters *params,
        const glm::vec3* obstacle_position,
        const float* obstacle_radius,
        const int obstacle_count,
        const BoidId *boid_id,
        const int *cell_start,
        const int *cell_end,
        glm::vec4 *position,
        glm::vec4 *position_old,
        glm::vec3 *velocity,
        glm::vec3 *velocity_old,
        glm::vec4 *forward,
        glm::vec4 *up,
        glm::vec4 *right,
        float dt
) {
    BoidId b_id = blockIdx.x * blockDim.x + threadIdx.x;
    int tid = threadIdx.x;

    if (b_id >= params->boids_count) return;

    __shared__ glm::vec4 s_position_old[BLOCK_SIZE];
    __shared__ glm::vec3 s_velocity_old[BLOCK_SIZE];
    s_position_old[tid] = position_old[b_id];
    s_velocity_old[tid] = velocity_old[b_id];
    __syncthreads();

    glm::vec3 acceleration(0.f);

    glm::vec3 separation(0.);
    glm::vec3 avg_vel(0.);
    glm::vec3 avg_pos(0.);
    uint32_t neighbors_count = 0;

    CellCoords cell_coords = get_cell_cords(params, position_old[b_id]);

    CellCoord grid_size_x = std::ceil(params->aquarium_size.x / params->distance);
    CellCoord grid_size_y = std::ceil(params->aquarium_size.y / params->distance);
    CellCoord grid_size_z = std::ceil(params->aquarium_size.z / params->distance);

    auto x_start = static_cast<CellCoord>(max(int(cell_coords.x) - 1, 0));
    auto x_end = static_cast<CellCoord>(min(cell_coords.x + 1, grid_size_x - 1));

    auto y_start = static_cast<CellCoord>(max(int(cell_coords.y) - 1, 0));
    auto y_end = static_cast<CellCoord>(min(cell_coords.y + 1, grid_size_y - 1));

    auto z_start = static_cast<CellCoord>(max(int(cell_coords.z) - 1, 0));
    auto z_end = static_cast<CellCoord>(min(cell_coords.z + 1, grid_size_z - 1));

    for (CellCoord curr_cell_z = z_start; curr_cell_z <= z_end; ++curr_cell_z) {
        for (CellCoord curr_cell_y = y_start; curr_cell_y <= y_end; ++curr_cell_y) {
            for (CellCoord curr_cell_x = x_start; curr_cell_x <= x_end; ++curr_cell_x) {
                if (curr_cell_x == cell_coords.x && curr_cell_y == cell_coords.y && curr_cell_z == cell_coords.z) {
                    continue;
                }
                CellId curr_flat_id = flatten_coords(
                        params,
                        curr_cell_x,
                        curr_cell_y,
                        curr_cell_z
                );

                for (int k = cell_start[curr_flat_id]; k < cell_end[curr_flat_id]; ++k) {
                    BoidId other_id = boid_id[k];

                    if (other_id == b_id) {
                        continue;
                    }

                    auto distance2 = glm::dot(s_position_old[tid] - position_old[other_id], s_position_old[tid] - position_old[other_id]);
                    if (distance2 > params->distance * params->distance) {
                        continue;
                    }

                    separation += glm::vec3(glm::normalize(s_position_old[tid] - position_old[other_id]) / distance2);
                    avg_vel += velocity_old[other_id];
                    avg_pos += glm::vec3(position_old[other_id]);

                    ++neighbors_count;
                }
            }
        }
    }

    // Update current cell
    CellId curr_flat_id = flatten_coords(
            params,
            cell_coords
    );

    for (int k = cell_start[curr_flat_id]; k < cell_end[curr_flat_id]; ++k) {
        BoidId other_id = boid_id[k];

        if (other_id == b_id) {
            continue;
        }

        auto distance2 = glm::dot(s_position_old[tid] - position_old[other_id], s_position_old[tid] - position_old[other_id]);
        if (distance2 > params->distance * params->distance) {
            continue;
        }

        int other_block_id = int(other_id) / BLOCK_SIZE;
        if (other_block_id == blockIdx.x) {
            int other_tid = int(other_id) % BLOCK_SIZE;
            separation += glm::vec3(glm::normalize(s_position_old[tid] - s_position_old[other_tid]) / distance2);
            avg_vel += s_velocity_old[other_tid];
            avg_pos += glm::vec3(s_position_old[other_tid]);
        } else {
            separation += glm::vec3(glm::normalize(s_position_old[tid] - position_old[other_id]) / distance2);
            avg_vel += velocity_old[other_id];
            avg_pos += glm::vec3(position_old[other_id]);
        }
        ++neighbors_count;
    }

    if (neighbors_count > 0) {
        avg_vel /= float(neighbors_count);
        avg_pos /= float(neighbors_count);

        // Final acceleration of the current boid
        acceleration =
                params->separation * separation +
                params->alignment * (avg_vel - s_velocity_old[tid]) +
                params->cohesion * (avg_pos - glm::vec3(s_position_old[tid]));
    }

    // Add noise
    curandState local_state = state[b_id];
    float x = curand_uniform(&local_state);
    float y = curand_uniform(&local_state);
    float z = curand_uniform(&local_state);
    state[b_id] = local_state;
    acceleration += glm::normalize(glm::vec3(2.f * (x - 0.5f), 2.f * (y - 0.5f), 2.f * (z - 0.5f))) * params->noise;

    // Update pos and vel
    update_pos_vel_shared(
            params,
            obstacle_position,
            obstacle_radius,
            obstacle_count,
            b_id,
            tid,
            position,
            s_position_old,
            velocity,
            s_velocity_old,
            acceleration,
            forward,
            up,
            right,
            dt
    );
}

__global__ void ker_update_simulation_with_sort1(
        const SimulationParameters *params,
        const glm::vec3* obstacle_position,
        const float* obstacle_radius,
        const int obstacle_count,
        const BoidId *boid_id,
        const int *cell_start,
        const int *cell_end,
        glm::vec4 *position,
        glm::vec4 *position_old,
        glm::vec3 *velocity,
        glm::vec3 *velocity_old,
        glm::vec4 *forward,
        glm::vec4 *up,
        glm::vec4 *right,
        float dt
) {
    BoidId b_id = blockIdx.x * blockDim.x + threadIdx.x;
    int tid = threadIdx.x;

    if (b_id >= params->boids_count) return;

    __shared__ glm::vec4 s_position_old[BLOCK_SIZE];
    __shared__ glm::vec3 s_velocity_old[BLOCK_SIZE];
    s_position_old[tid] = position_old[b_id];
    s_velocity_old[tid] = velocity_old[b_id];

    glm::vec3 acceleration(0.f);

    glm::vec3 separation(0.);
    glm::vec3 avg_vel(0.);
    glm::vec3 avg_pos(0.);
    uint32_t neighbors_count = 0;

    CellCoords cell_coords = get_cell_cords(params, position_old[b_id]);

    CellCoord grid_size_x = std::ceil(params->aquarium_size.x / params->distance);
    CellCoord grid_size_y = std::ceil(params->aquarium_size.y / params->distance);
    CellCoord grid_size_z = std::ceil(params->aquarium_size.z / params->distance);

    auto x_start = static_cast<CellCoord>(max(int(cell_coords.x) - 1, 0));
    auto x_end = static_cast<CellCoord>(min(cell_coords.x + 1, grid_size_x - 1));

    auto y_start = static_cast<CellCoord>(max(int(cell_coords.y) - 1, 0));
    auto y_end = static_cast<CellCoord>(min(cell_coords.y + 1, grid_size_y - 1));

    auto z_start = static_cast<CellCoord>(max(int(cell_coords.z) - 1, 0));
    auto z_end = static_cast<CellCoord>(min(cell_coords.z + 1, grid_size_z - 1));

    for (CellCoord curr_cell_z = z_start; curr_cell_z <= z_end; ++curr_cell_z) {
        for (CellCoord curr_cell_y = y_start; curr_cell_y <= y_end; ++curr_cell_y) {
            for (CellCoord curr_cell_x = x_start; curr_cell_x <= x_end; ++curr_cell_x) {
                CellId curr_flat_id = flatten_coords(
                        params,
                        curr_cell_x,
                        curr_cell_y,
                        curr_cell_z
                );

                for (int k = cell_start[curr_flat_id]; k < cell_end[curr_flat_id]; ++k) {
                    BoidId other_id = boid_id[k];

                    if (other_id == b_id) {
                        continue;
                    }

                    auto distance2 = glm::dot(s_position_old[tid] - position_old[other_id], s_position_old[tid] - position_old[other_id]);
                    if (distance2 > params->distance * params->distance) {
                        continue;
                    }

                    separation += glm::vec3(glm::normalize(s_position_old[tid] - position_old[other_id]) / distance2);
                    avg_vel += velocity_old[other_id];
                    avg_pos += glm::vec3(position_old[other_id]);

                    ++neighbors_count;
                }
            }
        }
    }

    if (neighbors_count > 0) {
        avg_vel /= float(neighbors_count);
        avg_pos /= float(neighbors_count);

        // Final acceleration of the current boid
        acceleration =
                params->separation * separation +
                params->alignment * (avg_vel - s_velocity_old[tid]) +
                params->cohesion * (avg_pos - glm::vec3(s_position_old[tid]));
    }

    // Add noise
    curandState local_state = state[b_id];
    float x = curand_uniform(&local_state);
    float y = curand_uniform(&local_state);
    float z = curand_uniform(&local_state);
    state[b_id] = local_state;
    acceleration += glm::normalize(glm::vec3(2.f * (x - 0.5f), 2.f * (y - 0.5f), 2.f * (z - 0.5f))) * params->noise;

    // Update pos and vel
    update_pos_vel_shared(
            params,
            obstacle_position,
            obstacle_radius,
            obstacle_count,
            b_id,
            tid,
            position,
            s_position_old,
            velocity,
            s_velocity_old,
            acceleration,
            forward,
            up,
            right,
            dt
    );
}

__global__ void ker_reset_simulation(
        const SimulationParameters *params,
        glm::vec4 *position_old,
        glm::vec3 *velocity_old,
        glm::vec4 *forward,
        glm::vec4 *up,
        glm::vec4 *right
) {
    BoidId b_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (b_id >= params->boids_count) return;

    curandState local_state = state[b_id];

    float x = (curand_uniform(&local_state) - 0.5f) * params->aquarium_size.x;
    float y = (curand_uniform(&local_state) - 0.5f) * params->aquarium_size.y;
    float z = (curand_uniform(&local_state) - 0.5f) * params->aquarium_size.z;

    position_old[b_id] = glm::vec4(x, y, z, 1.f);

    forward[b_id] = glm::vec4(0.f, 0.f, 1.f, 0.f);
    up[b_id] = glm::vec4(0.f, 1.f, 0.f, 0.f);
    right[b_id] = glm::vec4(1.f, 0.f, 0.f, 0.f);

    x = (curand_uniform(&local_state) - 0.5f) * 2.f;
    y = (curand_uniform(&local_state) - 0.5f) * 2.f;
    z = (curand_uniform(&local_state) - 0.5f) * 2.f;

    velocity_old[b_id] = glm::vec3(0.05f * glm::normalize(glm::vec3(x, y, z)));

    // Update basis vectors (orientation)
    update_orientation(forward, up, right, velocity_old, b_id);

    state[b_id] = local_state;
}

__global__ void init_starts(int *cell_start, int *cell_end, size_t count) {
    int k = blockIdx.x * blockDim.x + threadIdx.x;
    if (k >= count) {
        return;
    }
    cell_start[k] = 0;
    cell_end[k] = 0;
}

void check_cuda_error(const cudaError_t &cuda_status, const char *msg) {
    if (cuda_status != cudaSuccess) {
        std::cerr << msg << cudaGetErrorString(cuda_status) << std::endl;
        std::terminate();
    }
}

GPUBoids::GPUBoids(const boids::Boids& boids, const boids::BoidsRenderer& renderer) : m_gl_registered(false) {
    cudaError_t cuda_err;
    int gl_device_id;
    unsigned int gl_device_count;

	// Try to find and set opengl device
	cuda_err = cudaGLGetDevices(&gl_device_count, &gl_device_id, 1, cudaGLDeviceListAll);
	cuda_err = cudaSetDevice(gl_device_id);
    if (cuda_err == cudaSuccess) {
        std::cout << "[CUDA] Found cuda device attached to the current OpenGL context: " << gl_device_id << ". GL Buffers are going to be registered.\n";
		this->init_with_gl(boids, renderer);
	} else {
        std::cout << "[CUDA]: Couldn't find any cuda device attached to the current OpenGL context. GL buffers aren't going to be registered.\n";
        this->init_default(boids);
    }
}

GPUBoids::GPUBoids(const Boids& boids) : m_gl_registered(false) {
    this->init_default(boids);
}

void GPUBoids::init_default(const Boids& boids) {
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    for (int i = 0; i < deviceCount; ++i) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, i);
        printf("[CUDA] Device %d: Compute Capability %d.%d\n", i, prop.major, prop.minor);
    }

    size_t array_size_vec3 = SimulationParameters::MAX_BOID_COUNT * sizeof(glm::vec3);
    size_t array_size_vec4 = SimulationParameters::MAX_BOID_COUNT * sizeof(glm::vec4);

    cudaError_t cuda_status;

    // Allocate memory on the device using cudaMalloc
    cuda_status = cudaMalloc((void**)&m_dev_position, array_size_vec4);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_velocity, array_size_vec3);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_position_old, array_size_vec4);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_velocity_old, array_size_vec3);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_forward, array_size_vec4);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_up, array_size_vec4);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_right, array_size_vec4);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");

    cuda_status = cudaMalloc((void**)&m_dev_obstacle_radius, SimulationParameters::MAX_OBSTACLES_COUNT * sizeof(float));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_obstacle_position, SimulationParameters::MAX_OBSTACLES_COUNT * sizeof(glm::vec3));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");

    // Upload position, velocity and orientation to the gpu
    cuda_status = cudaMemcpy(m_dev_position_old, boids.position.data(), array_size_vec4, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(m_dev_velocity_old, boids.velocity.data(), array_size_vec3, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(m_dev_forward, boids.orientation.forward.data(), array_size_vec4, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(m_dev_up, boids.orientation.up.data(), array_size_vec4, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(m_dev_right, boids.orientation.right.data(), array_size_vec4, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");

    // Prepare simulation params container
    cuda_status = cudaMalloc((void**)&m_dev_sim_params, sizeof(SimulationParameters));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed ");

    // Prepare boid_id and cell_id
    cuda_status = cudaMalloc((void**)&m_dev_cell_id, SimulationParameters::MAX_BOID_COUNT * sizeof(CellId));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_boid_id, SimulationParameters::MAX_BOID_COUNT * sizeof(BoidId));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");

    // Prepare start and end arrays
    cuda_status = cudaMalloc((void**)&m_dev_cell_start, SimulationParameters::MAX_CELL_COUNT * sizeof(int));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_cell_end, SimulationParameters::MAX_CELL_COUNT * sizeof(int));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    init_starts<<<1024, SimulationParameters::MAX_CELL_COUNT / 1024 + 1>>>(m_dev_cell_start, m_dev_cell_end, SimulationParameters::MAX_CELL_COUNT);

    // Setup curand
    setup_curand<<<1024,SimulationParameters::MAX_BOID_COUNT / 1024 + 1>>>(SimulationParameters::MAX_BOID_COUNT);
}

void GPUBoids::init_with_gl(const Boids &boids, const BoidsRenderer &renderer) {
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    for (int i = 0; i < deviceCount; ++i) {
        cudaDeviceProp prop;
        cudaGetDeviceProperties(&prop, i);
        printf("[CUDA] Device %d: Compute Capability %d.%d\n", i, prop.major, prop.minor);
    }

    m_gl_registered = true;

    size_t array_size_vec3 = SimulationParameters::MAX_BOID_COUNT * sizeof(glm::vec3);
    size_t array_size_vec4 = SimulationParameters::MAX_BOID_COUNT * sizeof(glm::vec4);

    cudaError_t cuda_status;
    // Register OpenGL Buffers
    size_t buffer_size;
    renderer.cuda_register_vbos(&m_positionVBO_CUDA, &m_forwardVBO_CUDA, &m_upVBO_CUDA, &m_rightVBO_CUDA);
    cudaGraphicsMapResources(1, &m_positionVBO_CUDA, 0);
    cudaGraphicsResourceGetMappedPointer((void**)&m_dev_position_vbo, &buffer_size, m_positionVBO_CUDA);

    cudaGraphicsMapResources(1, &m_forwardVBO_CUDA, 0);
    cudaGraphicsResourceGetMappedPointer((void**)&m_dev_forward, &buffer_size, m_forwardVBO_CUDA);

    cudaGraphicsMapResources(1, &m_upVBO_CUDA, 0);
    cudaGraphicsResourceGetMappedPointer((void**)&m_dev_up, &buffer_size, m_upVBO_CUDA);

    cudaGraphicsMapResources(1, &m_rightVBO_CUDA, 0);
    cudaGraphicsResourceGetMappedPointer((void**)&m_dev_right, &buffer_size, m_rightVBO_CUDA);

    // Allocate memory on the device using cudaMalloc
    cuda_status = cudaMalloc((void**)&m_dev_position, array_size_vec4);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_velocity, array_size_vec3);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_position_old, array_size_vec4);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_velocity_old, array_size_vec3);
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    
    cuda_status = cudaMalloc((void**)&m_dev_obstacle_radius, SimulationParameters::MAX_OBSTACLES_COUNT * sizeof(float));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_obstacle_position, SimulationParameters::MAX_OBSTACLES_COUNT * sizeof(glm::vec3));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");

    // Upload position, velocity and orientation to the gpu
    cuda_status = cudaMemcpy(m_dev_position_old, boids.position.data(), array_size_vec4, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(m_dev_velocity_old, boids.velocity.data(), array_size_vec3, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");

    // Prepare simulation params container
    cuda_status = cudaMalloc((void**)&m_dev_sim_params, sizeof(SimulationParameters));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed ");

    // Prepare boid_id and cell_id
    cuda_status = cudaMalloc((void**)&m_dev_cell_id, SimulationParameters::MAX_BOID_COUNT * sizeof(CellId));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_boid_id, SimulationParameters::MAX_BOID_COUNT * sizeof(BoidId));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");

    // Prepare start and end arrays
    cuda_status = cudaMalloc((void**)&m_dev_cell_start, SimulationParameters::MAX_CELL_COUNT * sizeof(int));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    cuda_status = cudaMalloc((void**)&m_dev_cell_end, SimulationParameters::MAX_CELL_COUNT * sizeof(int));
    check_cuda_error(cuda_status, "[CUDA]: cudaMalloc failed: ");
    init_starts<<<1024, SimulationParameters::MAX_CELL_COUNT / 1024 + 1>>>(m_dev_cell_start, m_dev_cell_end, SimulationParameters::MAX_CELL_COUNT);

    // Setup curand
    setup_curand<<<1024, SimulationParameters::MAX_BOID_COUNT / 1024 + 1>>>(SimulationParameters::MAX_BOID_COUNT);
}

GPUBoids::~GPUBoids() {
    if (m_gl_registered) {
        cudaGraphicsUnmapResources(1, &m_positionVBO_CUDA, 0);
        cudaGraphicsUnmapResources(1, &m_forwardVBO_CUDA, 0);
        cudaGraphicsUnmapResources(1, &m_upVBO_CUDA, 0);
        cudaGraphicsUnmapResources(1, &m_rightVBO_CUDA, 0);
    } else {
        cudaFree(m_dev_forward);
        cudaFree(m_dev_up);
        cudaFree(m_dev_right);
    }
    cudaFree(m_dev_position);
    cudaFree(m_dev_position_old);
    cudaFree(m_dev_velocity_old);
    cudaFree(m_dev_velocity);
    cudaFree(m_dev_sim_params);
    cudaFree(m_dev_cell_id);
    cudaFree(m_dev_boid_id);
}

void GPUBoids::update_simulation_naive(const boids::SimulationParameters &params, const Obstacles &obstacles, Boids &boids, float dt) {
    cudaError_t cuda_status = cudaMemcpy(m_dev_sim_params, &params, sizeof(boids::SimulationParameters), cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    size_t threads_per_block = BLOCK_SIZE;
    size_t blocks_num = params.boids_count / threads_per_block + 1;

    cuda_status = cudaMemcpy(m_dev_obstacle_position, obstacles.get_pos_array(), SimulationParameters::MAX_OBSTACLES_COUNT * sizeof(glm::vec3), cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(m_dev_obstacle_radius, obstacles.get_radius_array(), SimulationParameters::MAX_OBSTACLES_COUNT * sizeof(float), cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");

    ker_update_simulation_naive<<<blocks_num, threads_per_block>>>(
            m_dev_sim_params,
            m_dev_obstacle_position,
            m_dev_obstacle_radius,
            obstacles.count(),
            m_dev_position,
            m_dev_position_old,
            m_dev_velocity,
            m_dev_velocity_old,
            m_dev_forward,
            m_dev_up,
            m_dev_right,
            dt
    );
    cudaDeviceSynchronize();

    if (!m_gl_registered) {
        move_boids_data_to_cpu(boids);
    }
    swap_buffers(params.boids_count);
}

void GPUBoids::update_simulation_with_sort(const boids::SimulationParameters &params, const Obstacles &obstacles, Boids &boids, float dt, int variant = 1) {
    cudaError_t cuda_status = cudaMemcpy(m_dev_sim_params, &params, sizeof(boids::SimulationParameters), cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    size_t threads_per_block = BLOCK_SIZE;
    size_t blocks_num = params.boids_count / threads_per_block + 1;

    cuda_status = cudaMemcpy(m_dev_obstacle_position, obstacles.get_pos_array(), SimulationParameters::MAX_OBSTACLES_COUNT * sizeof(glm::vec3), cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(m_dev_obstacle_radius, obstacles.get_radius_array(), SimulationParameters::MAX_OBSTACLES_COUNT * sizeof(float), cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");

    // 1. Update simulation parameters
    ker_find_cell_ids<<<blocks_num, threads_per_block>>>(
            m_dev_sim_params,
            m_dev_boid_id,
            m_dev_cell_id,
            m_dev_position_old
    );
    cudaDeviceSynchronize();

    // 2.
    thrust::sort_by_key(
            thrust::device,
            m_dev_cell_id,
            m_dev_cell_id + params.boids_count,
            m_dev_boid_id
    );
    cudaDeviceSynchronize();

    // 3.
    ker_find_starts<<<blocks_num, threads_per_block>>>(
            m_dev_cell_id,
            m_dev_cell_start,
            m_dev_cell_end,
            params.boids_count
    );
    cudaDeviceSynchronize();

    // 4.
    if (variant == 1) {
        ker_update_simulation_with_sort1<<<blocks_num, threads_per_block>>>(
                m_dev_sim_params,
                m_dev_obstacle_position,
                m_dev_obstacle_radius,
                obstacles.count(),
                m_dev_boid_id,
                m_dev_cell_start,
                m_dev_cell_end,
                m_dev_position,
                m_dev_position_old,
                m_dev_velocity,
                m_dev_velocity_old,
                m_dev_forward,
                m_dev_up,
                m_dev_right,
                dt
        );
    } else {
         ker_update_simulation_with_sort0<<<blocks_num, threads_per_block>>>(
                m_dev_sim_params,
                m_dev_obstacle_position,
                m_dev_obstacle_radius,
                obstacles.count(),
                m_dev_boid_id,
                m_dev_cell_start,
                m_dev_cell_end,
                m_dev_position,
                m_dev_position_old,
                m_dev_velocity,
                m_dev_velocity_old,
                m_dev_forward,
                m_dev_up,
                m_dev_right,
                dt
        );
    }
    cudaDeviceSynchronize();


    // 5.
    ker_clear_starts<<<blocks_num, threads_per_block>>>(
            m_dev_cell_id,
            m_dev_cell_start,
            m_dev_cell_end,
            params.boids_count
    );
    cudaDeviceSynchronize();

    if (!m_gl_registered) {
        move_boids_data_to_cpu(boids);
    }
    swap_buffers(params.boids_count);
}

void GPUBoids::reset(const SimulationParameters& params, const Boids& boids, const BoidsRenderer& renderer) {
    size_t array_size_vec3 = SimulationParameters::MAX_BOID_COUNT * sizeof(glm::vec3);
    size_t array_size_vec4 = SimulationParameters::MAX_BOID_COUNT * sizeof(glm::vec4);
    cudaError cuda_status;
    size_t buffer_size;

    cuda_status = cudaMemcpy(m_dev_position_old, boids.position.data(), array_size_vec4, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(m_dev_velocity_old, boids.velocity.data(), array_size_vec3, cudaMemcpyHostToDevice);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    
	if (m_gl_registered) {
		// Unregister the resources
		cudaGraphicsUnregisterResource(m_positionVBO_CUDA);
		cudaGraphicsUnregisterResource(m_forwardVBO_CUDA);
		cudaGraphicsUnregisterResource(m_upVBO_CUDA);
		cudaGraphicsUnregisterResource(m_rightVBO_CUDA);

		// Register new vbos buffers
		renderer.cuda_register_vbos(&m_positionVBO_CUDA, &m_forwardVBO_CUDA, &m_upVBO_CUDA, &m_rightVBO_CUDA);
		cudaGraphicsMapResources(1, &m_positionVBO_CUDA, 0);
		cudaGraphicsResourceGetMappedPointer((void**)&m_dev_position_vbo, &buffer_size, m_positionVBO_CUDA);

		cudaGraphicsMapResources(1, &m_forwardVBO_CUDA, 0);
		cudaGraphicsResourceGetMappedPointer((void**)&m_dev_forward, &buffer_size, m_forwardVBO_CUDA);

		cudaGraphicsMapResources(1, &m_upVBO_CUDA, 0);
		cudaGraphicsResourceGetMappedPointer((void**)&m_dev_up, &buffer_size, m_upVBO_CUDA);

		cudaGraphicsMapResources(1, &m_rightVBO_CUDA, 0);
		cudaGraphicsResourceGetMappedPointer((void**)&m_dev_right, &buffer_size, m_rightVBO_CUDA);
	}
	else {
		cuda_status = cudaMemcpy(m_dev_forward, boids.orientation.forward.data(), array_size_vec4, cudaMemcpyHostToDevice);
		check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
		cuda_status = cudaMemcpy(m_dev_up, boids.orientation.up.data(), array_size_vec4, cudaMemcpyHostToDevice);
		check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
		cuda_status = cudaMemcpy(m_dev_right, boids.orientation.right.data(), array_size_vec4, cudaMemcpyHostToDevice);
		check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
	}
}
void GPUBoids::move_boids_data_to_cpu(Boids &boids) {
    cudaError_t cuda_status;
    cuda_status = cudaMemcpy(boids.position.data(), m_dev_position, sizeof(glm::vec4) * SimulationParameters::MAX_BOID_COUNT, cudaMemcpyDeviceToHost);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(boids.orientation.forward.data(), m_dev_forward, sizeof(glm::vec4) * SimulationParameters::MAX_BOID_COUNT, cudaMemcpyDeviceToHost);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(boids.orientation.up.data(), m_dev_up,sizeof(glm::vec4) * SimulationParameters::MAX_BOID_COUNT, cudaMemcpyDeviceToHost);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
    cuda_status = cudaMemcpy(boids.orientation.right.data(), m_dev_right,sizeof(glm::vec4) * SimulationParameters::MAX_BOID_COUNT, cudaMemcpyDeviceToHost);
    check_cuda_error(cuda_status, "[CUDA]: cudaMemcpy failed: ");
}

void GPUBoids::swap_buffers(int count) {
	glm::vec4* temp_pos = m_dev_position;
	glm::vec3* temp_vel = m_dev_velocity;

	m_dev_position = m_dev_position_old;
	m_dev_velocity = m_dev_velocity_old;

	m_dev_position_old = temp_pos;
	m_dev_velocity_old = temp_vel;

	if (m_gl_registered) {
        cudaError_t cuda_status = cudaMemcpy(m_dev_position_vbo, m_dev_position_old, sizeof(glm::vec4) * count, cudaMemcpyDeviceToDevice);
        check_cuda_error(cuda_status, "[CUDA]: m_dev_poistion_vbo cudaMemcpy failed: ");

	}
}