package notosu


max_particles :: 1000

Particle :: struct {
    rect: Rect,
    vel: vec2,
    tex_index: u32
}

particles: [max_particles]Particle
particle_count: u32
particle_next: u32


push_particle :: proc(particle: Particle) {
    particles[particle_next] = particle
    particle_next = (particle_next + 1) % max_particles
    particle_count = min(particle_count + 1, max_particles)
}

update_particles :: proc(dt: f64) {
    for i in 0..<particle_count {
        particles[i].rect.x += particles[i].vel.x * f32(dt)
        particles[i].rect.y += particles[i].vel.y * f32(dt)
    }
}