#ifndef BOIDS_SIMULATION_BOIDS_CUDA_HPP
#define BOIDS_SIMULATION_BOIDS_CUDA_HPP
#include "boids.hpp"

namespace boids::cuda_gpu {
    using CellId = uint32_t;
    using CellCoord = uint32_t;

    struct CellCoords {
        CellCoord x, y, z;
    };

    class GPUBoids {
    public:
        GPUBoids() = delete;
        ~GPUBoids();
        explicit GPUBoids(const Boids& boids, const BoidsRenderer& renderer);
        explicit GPUBoids(const Boids& boids);

        void update_simulation_with_sort(const SimulationParameters& params, const Obstacles& obstacles, Boids &boids, float dt, int variant);
        void update_simulation_naive(const SimulationParameters &params, const Obstacles& obstacles, Boids &boids, float dt);

        void reset(const SimulationParameters& params, const Boids& boids, const BoidsRenderer& renderer);

        bool gl_buffers_registerd() const { return m_gl_registered; }
    private:
        void init_default(const Boids& boids);
        void init_with_gl(const Boids& boids, const BoidsRenderer& renderer);

        void move_boids_data_to_cpu(Boids &boids);

        void swap_buffers(int count);

    private:
        glm::vec4 *m_dev_position_old{};
        glm::vec3 *m_dev_velocity_old{};
        glm::vec4 *m_dev_position{};
        glm::vec3 *m_dev_velocity{};

        glm::vec3 *m_dev_obstacle_position{};
        float *m_dev_obstacle_radius{};

        glm::vec4 *m_dev_forward{};
        glm::vec4 *m_dev_up{};
        glm::vec4 *m_dev_right{};

        // cell_id -> boid_id
        CellId *m_dev_cell_id;
        BoidId *m_dev_boid_id;
        SimulationParameters *m_dev_sim_params;

        // Stores starting index of all elements in the queried cell.
        int *m_dev_cell_start;
        int *m_dev_cell_end;

        glm::vec4* m_dev_position_vbo{};

        cudaGraphicsResource *m_positionVBO_CUDA, *m_forwardVBO_CUDA, *m_upVBO_CUDA, *m_rightVBO_CUDA;

        bool m_gl_registered;
    };
}


#endif //BOIDS_SIMULATION_BOIDS_CUDA_HPP
