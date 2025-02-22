/*
 * Copyright (c) 2020-2022, NVIDIA CORPORATION.  All rights reserved.
 *
 * NVIDIA CORPORATION and its licensors retain all intellectual property
 * and proprietary rights in and to this software, related documentation
 * and any modifications thereto.  Any use, reproduction, disclosure or
 * distribution of this software and related documentation without an express
 * license agreement from NVIDIA CORPORATION is strictly prohibited.
 */

/** @file   triangle_bvh.cuh
 *  @author Thomas Müller & Alex Evans, NVIDIA
 *  @brief  CUDA/C++ triangle implementation.
 */

#pragma once

#include <neural-graphics-primitives/common.h>
#include <neural-graphics-primitives/common_device.cuh>

#include <tiny-cuda-nn/common.h>

NGP_NAMESPACE_BEGIN
// For triangle struct, a, b, and c are the 3D coordinates of its locations.
struct Triangle {
	NGP_HOST_DEVICE vec3 sample_uniform_position(const vec2& sample) const {
		// This function would be sampling within the triangle.
		// Returns the barycentric coordinate within the triangle.
		// Sampled with uniform probability.
		// All needs to sum to one.
		// 
		float sqrt_x = std::sqrt(sample.x);
		float factor0 = 1.0f - sqrt_x;
		float factor1 = sqrt_x * (1.0f - sample.y);
		float factor2 = sqrt_x * sample.y;

		return factor0 * a + factor1 * b + factor2 * c;
	}
	// Computing the surface area of the triangle.
	NGP_HOST_DEVICE float surface_area() const {
		return 0.5f * length(cross(b - a, c - a));
	}
	// Computing the normal of the triangle.
	NGP_HOST_DEVICE vec3 normal() const {
		return normalize(cross(b - a, c - a));
	}

	// based on https://www.iquilezles.org/www/articles/intersectors/intersectors.htm
	// Computing ray-triangle intersection.
	NGP_HOST_DEVICE float ray_intersect(const vec3 &ro, const vec3 &rd, vec3& n) const {
		vec3 v1v0 = b - a;
		vec3 v2v0 = c - a;
		vec3 rov0 = ro - a;
		n = cross(v1v0, v2v0);
		vec3 q = cross(rov0, rd);
		float d = 1.0f / dot(rd, n);
		float u = d * -dot(q, v2v0);
		float v = d *  dot(q, v1v0);
		float t = d * -dot(n, rov0);
		if (u < 0.0f || u > 1.0f || v < 0.0f || (u+v) > 1.0f || t < 0.0f) {
			t = std::numeric_limits<float>::max(); // No intersection
		}
		return t;
	}
	// Why not define n in the above method?
	NGP_HOST_DEVICE float ray_intersect(const vec3 &ro, const vec3 &rd) const {
		vec3 n;
		return ray_intersect(ro, rd, n);
	}

	// based on https://www.iquilezles.org/www/articles/distfunctions/distfunctions.htm
	// Compute distance between a point and the triangle.
	NGP_HOST_DEVICE float distance_sq(const vec3& pos) const {
		vec3 v21 = b - a; vec3 p1 = pos - a;
		vec3 v32 = c - b; vec3 p2 = pos - b;
		vec3 v13 = a - c; vec3 p3 = pos - c;
		vec3 nor = cross(v21, v13);

		return
			// inside/outside test
			(sign(dot(cross(v21, nor), p1)) + sign(dot(cross(v32, nor), p2)) + sign(dot(cross(v13, nor), p3)) < 2.0f)
			?
			// 3 edges
			std::min({
				length2(v21 * tcnn::clamp(dot(v21, p1) / length2(v21), 0.0f, 1.0f)-p1),
				length2(v32 * tcnn::clamp(dot(v32, p2) / length2(v32), 0.0f, 1.0f)-p2),
				length2(v13 * tcnn::clamp(dot(v13, p3) / length2(v13), 0.0f, 1.0f)-p3),
			})
			:
			// 1 face
			dot(nor, p1) * dot(nor, p1) / length2(nor);
	}
	
	NGP_HOST_DEVICE float distance(const vec3& pos) const {
		return std::sqrt(distance_sq(pos));
	}
	// Check if the point is inside the triangle or outside.
	NGP_HOST_DEVICE bool point_in_triangle(const vec3& p) const {
		// Move the triangle so that the point becomes the
		// triangles origin
		vec3 local_a = a - p;
		vec3 local_b = b - p;
		vec3 local_c = c - p;

		// The point should be moved too, so they are both
		// relative, but because we don't use p in the
		// equation anymore, we don't need it!
		// p -= p;

		// Compute the normal vectors for triangles:
		// u = normal of PBC
		// v = normal of PCA
		// w = normal of PAB

		vec3 u = cross(local_b, local_c);
		vec3 v = cross(local_c, local_a);
		vec3 w = cross(local_a, local_b);

		// Test to see if the normals are facing the same direction.
		// If yes, the point is inside, otherwise it isn't.
		return dot(u, v) >= 0.0f && dot(u, w) >= 0.0f;
	}
	// Finding the point on a line
	NGP_HOST_DEVICE vec3 closest_point_to_line(const vec3& a, const vec3& b, const vec3& c) const {
		float t = dot(c - a, b - a) / dot(b - a, b - a);
		t = std::max(std::min(t, 1.0f), 0.0f);
		return a + t * (b - a);
	}
	// Finding the distance between the point to each of the triangle's edge and return the smallest distance. 
	NGP_HOST_DEVICE vec3 closest_point(vec3 point) const {
		point -= dot(normal(), point - a) * normal();

		if (point_in_triangle(point)) {
			return point;
		}

		vec3 c1 = closest_point_to_line(a, b, point);
		vec3 c2 = closest_point_to_line(b, c, point);
		vec3 c3 = closest_point_to_line(c, a, point);

		float mag1 = length2(point - c1);
		float mag2 = length2(point - c2);
		float mag3 = length2(point - c3);

		float min = std::min({mag1, mag2, mag3});

		if (min == mag1) {
			return c1;
		} else if (min == mag2) {
			return c2;
		} else {
			return c3;
		}
	}
	// Computing the centroid of the triangle.
	NGP_HOST_DEVICE vec3 centroid() const {
		return (a + b + c) / 3.0f;
	}
	// Computing the centroid of the given dim. 
	NGP_HOST_DEVICE float centroid(int axis) const {
		return (a[axis] + b[axis] + c[axis]) / 3;
	}
	// getter
	NGP_HOST_DEVICE void get_vertices(vec3 v[3]) const {
		v[0] = a;
		v[1] = b;
		v[2] = c;
	}

	vec3 a, b, c;
};

inline std::ostream& operator<<(std::ostream& os, const ngp::Triangle& triangle) {
	os << "[";
	os << "a=[" << triangle.a.x << "," << triangle.a.y << "," << triangle.a.z << "], ";
	os << "b=[" << triangle.b.x << "," << triangle.b.y << "," << triangle.b.z << "], ";
	os << "c=[" << triangle.c.x << "," << triangle.c.y << "," << triangle.c.z << "]";
	os << "]";
	return os;
}

NGP_NAMESPACE_END
