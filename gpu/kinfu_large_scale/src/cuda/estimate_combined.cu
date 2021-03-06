/*
 * Software License Agreement (BSD License)
 *
 *  Point Cloud Library (PCL) - www.pointclouds.org
 *  Copyright (c) 2011, Willow Garage, Inc.
 * 
 *  All rights reserved.
 *
 *  Redistribution and use in source and binary forms, with or without
 *  modification, are permitted provided that the following conditions
 *  are met:
 *
 *   * Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   * Redistributions in binary form must reproduce the above
 *     copyright notice, this list of conditions and the following
 *     disclaimer in the documentation and/or other materials provided
 *     with the distribution.
 *   * Neither the name of Willow Garage, Inc. nor the names of its
 *     contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 *  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 *  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 *  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 *  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 *  COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 *  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 *  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 *  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 *  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 *  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 *  ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 *  POSSIBILITY OF SUCH DAMAGE.
 *
 */

//#include <pcl/gpu/utils/device/block.hpp>
//#include <pcl/gpu/utils/device/funcattrib.hpp>
#include "device.hpp"
#include "zc_cuda_utils.hpp"
//#include <pcl/console/time.h> //zc: tictoc
#include <time.h>

namespace pcl
{
  namespace device
  {
    //typedef double float_type;
	typedef float float_type;

    struct Combined
    {
      enum
      {
        CTA_SIZE_X = 32,
        CTA_SIZE_Y = 8,
        CTA_SIZE = CTA_SIZE_X * CTA_SIZE_Y
      };

      struct plus
      {
        __forceinline__ __device__ float
        operator () (const float_type &lhs, const volatile float_type& rhs) const 
        {
          return (lhs + rhs);
        }
      };

      Mat33 Rcurr;
      float3 tcurr;

      PtrStep<float> vmap_curr;
      PtrStep<float> nmap_curr;

      Mat33 Rprev_inv;
      float3 tprev;

      Intr intr;

      PtrStep<float> vmap_g_prev;
      PtrStep<float> nmap_g_prev;

      float distThres;
      float angleThres;

      int cols;
      int rows;

      mutable PtrStep<float_type> gbuf;

      __device__ __forceinline__ bool
      search (int x, int y, float3& n, float3& d, float3& s) const
      {
        float3 ncurr;
        ncurr.x = nmap_curr.ptr (y)[x];

        if (isnan (ncurr.x))
          return (false);

        float3 vcurr;
        vcurr.x = vmap_curr.ptr (y       )[x];
        vcurr.y = vmap_curr.ptr (y + rows)[x];
        vcurr.z = vmap_curr.ptr (y + 2 * rows)[x];

        float3 vcurr_g = Rcurr * vcurr + tcurr;

        float3 vcurr_cp = Rprev_inv * (vcurr_g - tprev);         // prev camera coo space

        int2 ukr;         //projection
        ukr.x = __float2int_rn (vcurr_cp.x * intr.fx / vcurr_cp.z + intr.cx);      //4
        ukr.y = __float2int_rn (vcurr_cp.y * intr.fy / vcurr_cp.z + intr.cy);                      //4

        if (ukr.x < 0 || ukr.y < 0 || ukr.x >= cols || ukr.y >= rows || vcurr_cp.z < 0)
          return (false);

        float3 nprev_g;
        nprev_g.x = nmap_g_prev.ptr (ukr.y)[ukr.x];

        if (isnan (nprev_g.x))
          return (false);

        float3 vprev_g;
        vprev_g.x = vmap_g_prev.ptr (ukr.y       )[ukr.x];
        vprev_g.y = vmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        vprev_g.z = vmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float dist = norm (vprev_g - vcurr_g);
        if (dist > distThres)
          return (false);

        ncurr.y = nmap_curr.ptr (y + rows)[x];
        ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];

        float3 ncurr_g = Rcurr * ncurr;

        nprev_g.y = nmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        nprev_g.z = nmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float sine = norm (cross (ncurr_g, nprev_g));

        if (sine >= angleThres)
          return (false);
        n = nprev_g;
        d = vprev_g;
        s = vcurr_g;
        return (true);
      }

      __device__ __forceinline__ void
      operator () () const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        float3 n, d, s;
        bool found_coresp = false;

        if (x < cols && y < rows)
          found_coresp = search (x, y, n, d, s);

        float row[7];

        if (found_coresp)
        {
          *(float3*)&row[0] = cross (s, n);
          *(float3*)&row[3] = n;
          row[6] = dot (n, d - s);
        }
        else
          row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;

        __shared__ float_type smem[CTA_SIZE];
        int tid = Block::flattenedThreadId ();

        int shift = 0;
        #pragma unroll
        for (int i = 0; i < 6; ++i)        //rows
        {
          #pragma unroll
          for (int j = i; j < 7; ++j)          // cols + b
          {
            __syncthreads ();
            smem[tid] = row[i] * row[j];
            __syncthreads ();

            Block::reduce<CTA_SIZE>(smem, plus ());

            if (tid == 0)
              gbuf.ptr (shift++)[blockIdx.x + gridDim.x * blockIdx.y] = smem[0];
          }
        }
      }
    };

    __global__ void
    combinedKernel (const Combined cs) 
    {
      cs ();
    }

    struct TranformReduction
    {
      enum
      {
        CTA_SIZE = 512,
        STRIDE = CTA_SIZE,

        B = 6, COLS = 6, ROWS = 6, DIAG = 6,
        UPPER_DIAG_MAT = (COLS * ROWS - DIAG) / 2 + DIAG,
        TOTAL = UPPER_DIAG_MAT + B,

        GRID_X = TOTAL
      };

      PtrStep<float_type> gbuf;
      int length;
      mutable float_type* output;

      __device__ __forceinline__ void
      operator () () const
      {
        const float_type *beg = gbuf.ptr (blockIdx.x);
        const float_type *end = beg + length;

        int tid = threadIdx.x;

        float_type sum = 0.f;
        for (const float_type *t = beg + tid; t < end; t += STRIDE)
          sum += *t;

        __shared__ float_type smem[CTA_SIZE];

        smem[tid] = sum;
        __syncthreads ();

		Block::reduce<CTA_SIZE>(smem, Combined::plus ());

        if (tid == 0)
          output[blockIdx.x] = smem[0];
      }
    };

    __global__ void
    TransformEstimatorKernel2 (const TranformReduction tr) 
    {
      tr ();
    }

    struct Combined2
    {
      enum
      {
        CTA_SIZE_X = 32,
        CTA_SIZE_Y = 8,
        CTA_SIZE = CTA_SIZE_X * CTA_SIZE_Y
      };

      struct plus
      {
        __forceinline__ __device__ float
        operator () (const float_type &lhs, const volatile float_type& rhs) const 
        {
          return (lhs + rhs);
        }
      };

      Mat33 Rcurr;
      float3 tcurr;

      PtrStep<float> vmap_curr;
      PtrStep<float> nmap_curr;

      Mat33 Rprev_inv;
      float3 tprev;

      Intr intr;

      PtrStep<float> vmap_g_prev;
      PtrStep<float> nmap_g_prev;

      float distThres;
      float angleThres;

      int cols;
      int rows;

      mutable PtrStep<float_type> gbuf;

      __device__ __forceinline__ bool
      search (int x, int y, float3& n, float3& d, float3& s) const
      {
        float3 ncurr;
        ncurr.x = nmap_curr.ptr (y)[x];

        if (isnan (ncurr.x))
          return (false);

        float3 vcurr;
        vcurr.x = vmap_curr.ptr (y       )[x];
        vcurr.y = vmap_curr.ptr (y + rows)[x];
        vcurr.z = vmap_curr.ptr (y + 2 * rows)[x];

        float3 vcurr_g = Rcurr * vcurr + tcurr;

        float3 vcurr_cp = Rprev_inv * (vcurr_g - tprev);         // prev camera coo space

        int2 ukr;         //projection
        ukr.x = __float2int_rn (vcurr_cp.x * intr.fx / vcurr_cp.z + intr.cx);      //4
        ukr.y = __float2int_rn (vcurr_cp.y * intr.fy / vcurr_cp.z + intr.cy);                      //4

        if (ukr.x < 0 || ukr.y < 0 || ukr.x >= cols || ukr.y >= rows || vcurr_cp.z < 0)
          return (false);

        float3 nprev_g;
        nprev_g.x = nmap_g_prev.ptr (ukr.y)[ukr.x];

        if (isnan (nprev_g.x))
          return (false);

        float3 vprev_g;
        vprev_g.x = vmap_g_prev.ptr (ukr.y       )[ukr.x];

        //zc: fix @2017-4-13 16:20:12
        if (isnan (vprev_g.x))
          return (false);

        vprev_g.y = vmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        vprev_g.z = vmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float dist = norm (vprev_g - vcurr_g);
        if (dist > distThres)
          return (false);

        ncurr.y = nmap_curr.ptr (y + rows)[x];
        ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];

        float3 ncurr_g = Rcurr * ncurr;

        nprev_g.y = nmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        nprev_g.z = nmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float sine = norm (cross (ncurr_g, nprev_g));

        if (sine >= angleThres)
          return (false);
        n = nprev_g;
        d = vprev_g;
        s = vcurr_g;
        return (true);
      }

      __device__ __forceinline__ bool
      searchDbg (int x, int y, float3& n, float3& d, float3& s) const
      {
        float3 ncurr;
        ncurr.x = nmap_curr.ptr (y)[x];

        if (isnan (ncurr.x))
          return (false);

        float3 vcurr;
        vcurr.x = vmap_curr.ptr (y       )[x];
        vcurr.y = vmap_curr.ptr (y + rows)[x];
        vcurr.z = vmap_curr.ptr (y + 2 * rows)[x];

        float3 vcurr_g = Rcurr * vcurr + tcurr;

        float3 vcurr_cp = Rprev_inv * (vcurr_g - tprev);         // prev camera coo space

        int2 ukr;         //projection
        ukr.x = __float2int_rn (vcurr_cp.x * intr.fx / vcurr_cp.z + intr.cx);      //4
        ukr.y = __float2int_rn (vcurr_cp.y * intr.fy / vcurr_cp.z + intr.cy);                      //4

        if (ukr.x < 0 || ukr.y < 0 || ukr.x >= cols || ukr.y >= rows || vcurr_cp.z < 0)
          return (false);

        float3 nprev_g;
        nprev_g.x = nmap_g_prev.ptr (ukr.y)[ukr.x];

        if (isnan (nprev_g.x))
          return (false);

        float3 vprev_g;
        vprev_g.x = vmap_g_prev.ptr (ukr.y       )[ukr.x];
        vprev_g.y = vmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        vprev_g.z = vmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

		//zc: dbg
		printf("\t@searchDbg: ukr.xy=(%d, %d); isnan(nprev_g.x): %d; isnan (vprev_g.x): %d\n", ukr.x, ukr.y, isnan(nprev_g.x), isnan(vprev_g.x));

        float dist = norm (vprev_g - vcurr_g);
        if (dist > distThres)
          return (false);

        ncurr.y = nmap_curr.ptr (y + rows)[x];
        ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];

        float3 ncurr_g = Rcurr * ncurr;

        nprev_g.y = nmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        nprev_g.z = nmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float sine = norm (cross (ncurr_g, nprev_g));

        if (sine >= angleThres)
          return (false);
        n = nprev_g;
        d = vprev_g;
        s = vcurr_g;
        return (true);
      }//searchDbg

      __device__ __forceinline__ void
      operator () () const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        float3 n, d, s;
        bool found_coresp = false;

        if (x < cols && y < rows)
          found_coresp = search (x, y, n, d, s);

#if 0	//zc: dbg
		//if(x == 320 && y == 240){ //×
		if(x == cols/2 && y == rows/2){
			printf("@operator():: (x, y)=(%d, %d), found_coresp= %d; n=(%f, %f, %f), d=(%f, %f, %f), s=(%f, %f, %f)\n", x, y, 
				found_coresp, n.x, n.y, n.z, d.x, d.y, d.z, s.x, s.y, s.z);
		}
#endif

        float row[7];

        if (found_coresp)
        {
          *(float3*)&row[0] = cross (s, n);
          *(float3*)&row[3] = n;
          row[6] = dot (n, d - s);
		  //zc: dbg
		  if(isnan(row[6])){ //理论上完全不应该发生！！
			  printf("isnan(row[6]), (x,y)=(%d, %d); (rows, cols)=(%d, %d); n=(%f, %f, %f), d=(%f, %f, %f), s=(%f, %f, %f)\n", x, y, rows, cols,
				  n.x, n.y, n.z, d.x, d.y, d.z, s.x, s.y, s.z);
			  searchDbg(x, y, n, d, s);
		  }

#if 0	//不对, 不能加到一块, 因为多惩罚项打破了 线性最小二乘 形式, 是非线性了 @2017-6-1 11:06:13
		  //zc: 按耿老师要求, 增加 nmap 做惩罚项, //但只能惩罚 R, 不带 t @2017-5-31 11:16:49
		  //影响 row[0~2, 6], 不影响 row[3~5]
		  float3 ncurr;
		  ncurr.x = nmap_curr.ptr (y)[x];
		  ncurr.y = nmap_curr.ptr (y + rows)[x];
		  ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];
		  
		  float3 ncurr_g = Rcurr * ncurr;
		  if(dot(ncurr_g, n) < 0) //判断方向, 希望与 nprev_g 保持一致
			  ncurr_g *= -1;

		  //注意: n 是 nprev_g 
		  float3 tmpv = ncurr_g - n;
		  *(float3*)&row[0] = *(float3*)&row[0] + cross(ncurr_g, tmpv); //3x1 向量
		  row[6] = row[6] - dot(tmpv, tmpv); //①标量 ②注意这里 “-=”, 有原因, 推导略
#endif

#if 0
		  {
			  float3 cross_ng_v = cross(ncurr_g, tmpv);
			  float3 row03 = *(float3*)&row[0];
			  float3 row03_new = row03 + cross_ng_v;
			  //printf("ncurr_g=(%f, %f, %f), nprev_g=(%f, %f, %f)\n", ncurr_g.x, ncurr_g.y, ncurr_g.z, n.x, n.y, n.z);
			  printf("ncurr_g=(%f, %f, %f), nprev_g=(%f, %f, %f)\
					 \ntmpv=(%f, %f, %f), row03=(%f, %f, %f), cross_ng_v=(%f, %f, %f), row03_new=(%f, %f, %f), row6=%f, row6_new=%f\n", 
					 ncurr_g.x, ncurr_g.y, ncurr_g.z, n.x, n.y, n.z,
				  tmpv.x, tmpv.y, tmpv.z, 
				  row03.x, row03.y, row03.z,
				  cross_ng_v.x, cross_ng_v.y, cross_ng_v.z, 
				  row03_new.x, row03_new.y, row03_new.z, 
				  row[6], row[6] - dot(tmpv, tmpv));

		  }
#endif
        }
        else
          row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;

        int tid = Block::flattenedThreadId ();

        int shift = 0;
        #pragma unroll
        for (int i = 0; i < 6; ++i)        //rows
        {
          #pragma unroll
          for (int j = i; j < 7; ++j)          // cols + b
          {
              gbuf.ptr (shift++)[ (blockIdx.x + gridDim.x * blockIdx.y) * CTA_SIZE + tid ] = row[i]*row[j];
          }
        }
      }

      __device__ __forceinline__ void
      operator () (int dummy) const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        float3 n, d, s;
        bool found_coresp = false;

        if (x < cols && y < rows)
          found_coresp = search (x, y, n, d, s);

#if 0	//zc: dbg
		//if(x == 320 && y == 240){ //×
		if(x == cols/2 && y == rows/2){
			printf("@operator():: (x, y)=(%d, %d), found_coresp= %d; n=(%f, %f, %f), d=(%f, %f, %f), s=(%f, %f, %f)\n", x, y, 
				found_coresp, n.x, n.y, n.z, d.x, d.y, d.z, s.x, s.y, s.z);
		}
#endif

        float row[7];

        if (found_coresp)
        {
#if 0	//改, 这里要用 nmap 惩罚项, 仅优化 R, 不动 t (系数填零) @2017-6-1 14:47:31
          *(float3*)&row[0] = cross (s, n);
          *(float3*)&row[3] = n;
          row[6] = dot (n, d - s);
#elif 1
          float3 ncurr;
          ncurr.x = nmap_curr.ptr (y)[x];
          ncurr.y = nmap_curr.ptr (y + rows)[x];
          ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];
          
          float3 ncurr_g = Rcurr * ncurr;
          if(dot(ncurr_g, n) < 0) //判断方向, 希望与 nprev_g 保持一致
              ncurr_g *= -1;

          //注意: n 是 nprev_g 
#if 0	//此处思路是 argmin(SUM(|(R*ng~-ng)*(ng~-ng)|))
          //还不对, 错了, 放弃 @2017-6-2 17:48:13
          float3 tmpv = ncurr_g - n;
          *(float3*)&row[0] = cross(ncurr_g, tmpv); //3x1 向量
          row[3] = row[4] = row[5] = 0.f;
          row[6] = -dot(tmpv, tmpv); //①标量 ②注意这里 “-=”, 有原因, 推导略

#elif 1	//发现其实仍是 orthogonal-procrustes 问题, 这里尝试并行化方案 @2017-6-2 17:48:49
          //目标: argmin|RA-B| ==> R = svd(B*At), 例如 A/B 都 3*N, 则 BAt~3x3
          //row0~2 -> ncurr_g, 3~5-> nprev_g, [6]不管, 不用他
          //之后 gbuf[27] 只用前 3x3=9 行, 
          *(float3*)&row[0] = ncurr_g;
          *(float3*)&row[3] = n;
          row[6] = 0;
#endif

#endif
		  //zc: dbg
		  if(isnan(row[6])){ //理论上完全不应该发生！！
			  printf("isnan(row[6]), (x,y)=(%d, %d); (rows, cols)=(%d, %d); n=(%f, %f, %f), d=(%f, %f, %f), s=(%f, %f, %f)\n", x, y, rows, cols,
				  n.x, n.y, n.z, d.x, d.y, d.z, s.x, s.y, s.z);
			  searchDbg(x, y, n, d, s);
		  }

#if 0	//不对, 不能加到一块, 因为多惩罚项打破了 线性最小二乘 形式, 是非线性了 @2017-6-1 11:06:13
		  //zc: 按耿老师要求, 增加 nmap 做惩罚项, //但只能惩罚 R, 不带 t @2017-5-31 11:16:49
		  //影响 row[0~2, 6], 不影响 row[3~5]
		  float3 ncurr;
		  ncurr.x = nmap_curr.ptr (y)[x];
		  ncurr.y = nmap_curr.ptr (y + rows)[x];
		  ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];
		  
		  float3 ncurr_g = Rcurr * ncurr;
		  if(dot(ncurr_g, n) < 0) //判断方向, 希望与 nprev_g 保持一致
			  ncurr_g *= -1;

		  //注意: n 是 nprev_g 
		  float3 tmpv = ncurr_g - n;
		  *(float3*)&row[0] = *(float3*)&row[0] + cross(ncurr_g, tmpv); //3x1 向量
		  row[6] = row[6] - dot(tmpv, tmpv); //①标量 ②注意这里 “-=”, 有原因, 推导略
#endif

#if 0
		  {
			  float3 cross_ng_v = cross(ncurr_g, tmpv);
			  float3 row03 = *(float3*)&row[0];
			  float3 row03_new = row03 + cross_ng_v;
			  //printf("ncurr_g=(%f, %f, %f), nprev_g=(%f, %f, %f)\n", ncurr_g.x, ncurr_g.y, ncurr_g.z, n.x, n.y, n.z);
			  printf("ncurr_g=(%f, %f, %f), nprev_g=(%f, %f, %f)\
					 \ntmpv=(%f, %f, %f), row03=(%f, %f, %f), cross_ng_v=(%f, %f, %f), row03_new=(%f, %f, %f), row6=%f, row6_new=%f\n", 
					 ncurr_g.x, ncurr_g.y, ncurr_g.z, n.x, n.y, n.z,
				  tmpv.x, tmpv.y, tmpv.z, 
				  row03.x, row03.y, row03.z,
				  cross_ng_v.x, cross_ng_v.y, cross_ng_v.z, 
				  row03_new.x, row03_new.y, row03_new.z, 
				  row[6], row[6] - dot(tmpv, tmpv));

		  }
#endif
        }
        else
          row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;

        int tid = Block::flattenedThreadId ();

        int shift = 0;
#if 0   //gbuf 用作 21上三角+6=27 时
        #pragma unroll
        for (int i = 0; i < 6; ++i)        //rows
        {
          #pragma unroll
          for (int j = i; j < 7; ++j)          // cols + b
          {
              gbuf.ptr (shift++)[ (blockIdx.x + gridDim.x * blockIdx.y) * CTA_SIZE + tid ] = row[i]*row[j];
          }
        }
#elif 1 //gbuf 仅用前 3x3=9, 解 orthogonal-procrustes 问题时 @2017-6-2 17:55:44
        #pragma unroll
        for(int j=3; j<6; ++j){ //RA-B 问题中, 这里 3~5对应 B
            #pragma unroll
            for(int i=0; i<3; ++i){ //0~2 对应 A
                gbuf.ptr (shift++)[ (blockIdx.x + gridDim.x * blockIdx.y) * CTA_SIZE + tid ] = row[j] * row[i];
            }
        }
#endif
      }//operator () (int dummy) const


    };

    __global__ void
    combinedKernel2 (const Combined2 cs) 
    {
      cs ();
    }

    __global__ void
    combinedKernel2_nmap (const Combined2 cs) 
    {
      cs (1234567); //dummy 参数
    }

    struct CombinedPrevSpace
    {
      enum
      {
        CTA_SIZE_X = 32,
        CTA_SIZE_Y = 8,
        CTA_SIZE = CTA_SIZE_X * CTA_SIZE_Y
      };

      struct plus
      {
        __forceinline__ __device__ float
        operator () (const float_type &lhs, const volatile float_type& rhs) const 
        {
          return (lhs + rhs);
        }
      };

      Mat33 Rcurr;
      float3 tcurr;

      PtrStep<float> vmap_curr;
      PtrStep<float> nmap_curr;

      Mat33 Rprev_inv;
      float3 tprev;

      Intr intr;

      PtrStep<float> vmap_g_prev;
      PtrStep<float> nmap_g_prev;

      float distThres;
      float angleThres;

      int cols;
      int rows;

      mutable PtrStep<float_type> gbuf;

      __device__ __forceinline__ bool
      search (int x, int y, float3& n, float3& d, float3& s) const
      {
        float3 ncurr;
        ncurr.x = nmap_curr.ptr (y)[x];

        if (isnan (ncurr.x))
          return (false);

        float3 vcurr;
        vcurr.x = vmap_curr.ptr (y       )[x];
        vcurr.y = vmap_curr.ptr (y + rows)[x];
        vcurr.z = vmap_curr.ptr (y + 2 * rows)[x];

        float3 vcurr_g = Rcurr * vcurr + tcurr;

        float3 vcurr_cp = Rprev_inv * (vcurr_g - tprev);         // prev camera coo space

        int2 ukr;         //projection
        ukr.x = __float2int_rn (vcurr_cp.x * intr.fx / vcurr_cp.z + intr.cx);      //4
        ukr.y = __float2int_rn (vcurr_cp.y * intr.fy / vcurr_cp.z + intr.cy);                      //4

        if (ukr.x < 0 || ukr.y < 0 || ukr.x >= cols || ukr.y >= rows || vcurr_cp.z < 0)
          return (false);

        float3 nprev_g;
        nprev_g.x = nmap_g_prev.ptr (ukr.y)[ukr.x];

        if (isnan (nprev_g.x))
          return (false);

        float3 vprev_g;
        vprev_g.x = vmap_g_prev.ptr (ukr.y       )[ukr.x];
        vprev_g.y = vmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        vprev_g.z = vmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float dist = norm (vprev_g - vcurr_g);
        if (dist > distThres)
          return (false);

        ncurr.y = nmap_curr.ptr (y + rows)[x];
        ncurr.z = nmap_curr.ptr (y + 2 * rows)[x];

        float3 ncurr_g = Rcurr * ncurr;

        nprev_g.y = nmap_g_prev.ptr (ukr.y + rows)[ukr.x];
        nprev_g.z = nmap_g_prev.ptr (ukr.y + 2 * rows)[ukr.x];

        float sine = norm (cross (ncurr_g, nprev_g));

        if (sine >= angleThres)
          return (false);
        n = Rprev_inv * nprev_g;
        d = Rprev_inv * (vprev_g - tprev);
        s = vcurr_cp;
        return (true);
      }

      __device__ __forceinline__ void
      operator () () const
      {
        int x = threadIdx.x + blockIdx.x * CTA_SIZE_X;
        int y = threadIdx.y + blockIdx.y * CTA_SIZE_Y;

        float3 n, d, s;
        bool found_coresp = false;

        if (x < cols && y < rows)
          found_coresp = search (x, y, n, d, s);

        float row[7];

        if (found_coresp)
        {
          *(float3*)&row[0] = cross (s, n);
          *(float3*)&row[3] = n;
          row[6] = dot (n, d - s);
        }
        else
          row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;

        int tid = Block::flattenedThreadId ();

        int shift = 0;
        #pragma unroll
        for (int i = 0; i < 6; ++i)        //rows
        {
          #pragma unroll
          for (int j = i; j < 7; ++j)          // cols + b
          {
              gbuf.ptr (shift++)[ (blockIdx.x + gridDim.x * blockIdx.y) * CTA_SIZE + tid ] = row[i]*row[j];
          }
        }
      }
    };

    __global__ void
    combinedKernelPrevSpace (const CombinedPrevSpace cs) 
    {
      cs ();
    }

    __global__ void
    scaleDepth (const PtrStepSz<ushort> depth, PtrStep<float> scaled, const Intr intr);
    __global__ void
    scaleDepth_vmap (const PtrStepSz<float> vmap_g, float3 tvec, PtrStep<float> scaled, const Intr intr);

    //__device__ __forceinline__ float3
    //getVoxelGCoo (int x, int y, int z) /*const*/
    //{
    //  float3 coo = make_float3 (x, y, z);
    //  coo += 0.5f;         //shift to cell center;

    //  coo.x *= cell_size.x;
    //  coo.y *= cell_size.y;
    //  coo.z *= cell_size.z;

    //  return coo;
    //}

    //↓--count how many vxls are used in the cost function optimization
    __device__ int vxlValidCnt_device;
    __device__ float sumS2sErr_device;
    __device__ float tsdfDiffSum_device;
    __device__ float tsdfAbsDiffSum_device;

    //参考 tsdf23_v11_remake
    __global__ void
    estimateCombined_s2s_kernel(const PtrStepSz<float> depthScaled, PtrStep<short2> volume, PtrStep<short2> volume2, 
        const float tranc_dist, const float eta, //s2s (delta, eta)
        const Mat33 Rcurr_inv, const float3 tcurr, 
        const float3 volume000_gcoo, float6 xi_prev, 
        const Intr intr, const float3 cell_size, 
        PtrStep<float> gbuf, 
        int3 vxlDbg)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;

      //if (x >= VOLUME_X || y >= VOLUME_Y)
      if (x <= 1 || y <= 1 || x >= VOLUME_X-1 || y >= VOLUME_Y-1) //因 pos2 用到邻域算tsdf隐函数梯度
          return;

      //float v_g_x = (x + 0.5f) * cell_size.x - tcurr.x;
      //float v_g_y = (y + 0.5f) * cell_size.y - tcurr.y;
      //float v_g_z = (0 + 0.5f) * cell_size.z - tcurr.z;
      float v_g_x = (x + 0.5f) * cell_size.x + volume000_gcoo.x - tcurr.x;
      float v_g_y = (y + 0.5f) * cell_size.y + volume000_gcoo.y - tcurr.y;
      float v_g_z = (0 + 0.5f) * cell_size.z + volume000_gcoo.z - tcurr.z;

      float v_g_part_norm = v_g_x * v_g_x + v_g_y * v_g_y;

      float v_x = (Rcurr_inv.data[0].x * v_g_x + Rcurr_inv.data[0].y * v_g_y + Rcurr_inv.data[0].z * v_g_z) * intr.fx;
      float v_y = (Rcurr_inv.data[1].x * v_g_x + Rcurr_inv.data[1].y * v_g_y + Rcurr_inv.data[1].z * v_g_z) * intr.fy;
      float v_z = (Rcurr_inv.data[2].x * v_g_x + Rcurr_inv.data[2].y * v_g_y + Rcurr_inv.data[2].z * v_g_z);

      float z_scaled = 0;

      float Rcurr_inv_0_z_scaled = Rcurr_inv.data[0].z * cell_size.z * intr.fx;
      float Rcurr_inv_1_z_scaled = Rcurr_inv.data[1].z * cell_size.z * intr.fy;

      float tranc_dist_inv = 1.0f / tranc_dist;

      //model /global
      short2* pos = volume.ptr (y) + x;
      int elem_step = volume.step * VOLUME_Y / sizeof(short2);

      //curr
      short2* pos2 = volume2.ptr (y) + x;
      int elem_step2 = volume2.step * VOLUME_Y / sizeof(short2);

      //float row[7]; //放循环外

      for (int z = 0; z < VOLUME_Z;
      //for (int z = 1; z < VOLUME_Z - 1; //错！导致 idx 偏了
           ++z,
           v_g_z += cell_size.z,
           z_scaled += cell_size.z,
           v_x += Rcurr_inv_0_z_scaled,
           v_y += Rcurr_inv_1_z_scaled,
           pos += elem_step,
           pos2 += elem_step2)
      {
        bool doDbgPrint = false;
        if(x > 0 && y > 0 && z > 0 //参数默认 000, 做无效值, 所以增加此检测
            && vxlDbg.x == x && vxlDbg.y == y && vxlDbg.z == z)
            doDbgPrint = true;
        
        //放到for最前面
        if(0 == z){ //for-loop-begin-set-0
            int tid = Block::flattenedThreadId ();
            int total_tid = (blockIdx.x + gridDim.x * blockIdx.y) * (blockDim.x * blockDim.y) + tid;

            int shift = 0;

            #pragma unroll
            for (int i = 0; i < 6; ++i)        //rows
                #pragma unroll
                for (int j = i; j < 7; ++j)          // cols + b
                    gbuf.ptr (shift++)[ total_tid ] = 0;
        }
        if(0 == z || VOLUME_Z -1 == z){
            if(doDbgPrint)
                printf("######################(0 == z || VOLUME_Z -1 == z)\n");
            continue;
        }

        float inv_z = 1.0f / (v_z + Rcurr_inv.data[2].z * z_scaled);
        if (inv_z < 0)
            continue;

        // project to current cam
        int2 coo =
        {
          __float2int_rn (v_x * inv_z + intr.cx),
          __float2int_rn (v_y * inv_z + intr.cy)
        };

        if(doDbgPrint)
            printf("esti-s2s_kernel:: coo.xy:(%d, %d)\n", coo.x, coo.y);

        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
        {
          //float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters

          //float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          //if(doDbgPrint){
          //    printf("Dp_scaled, sdf, tranc_dist, %f, %f, %f\n", Dp_scaled, sdf, tranc_dist);
          //    printf("coo.xy:(%d, %d)\n", coo.x, coo.y);
          //}

          //float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          ////if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          //if (Dp_scaled != 0 && sdf >= -eta) //meters //比较 eta , 而非 delta (tdist)
          //{
          //  //read and unpack
          //  float tsdf_prev;
          //  int weight_prev;
          //  unpack_tsdf (*pos, tsdf_prev, weight_prev);
          //  //v17, 为配合 v17 用 w 二进制末位做标记位, 这里稍作修改: unpack 时 /2, pack 时 *2; @2018-1-22 02:01:27
          //  weight_prev = weight_prev >> 1;

          //  if(weight_prev == 0)
          //      continue;

          //  //↑--prev, ↓--curr
          //  float tsdf = fmin (1.0f, sdf * tranc_dist_inv);
          //  if(sdf < -tranc_dist)
          //      tsdf = -1.0f;

          //  const int Wrk = 1; //sdf>-eta ==> wrk=0 已经外层滤掉了, 不必再判断
          //  if(tsdf == tsdf_prev)
          //      continue;

          float tsdf1;
          int weight1;
          unpack_tsdf (*pos, tsdf1, weight1);
          //v17, 为配合 v17 用 w 二进制末位做标记位, 这里稍作修改: unpack 时 /2, pack 时 *2; @2018-1-22 02:01:27
          weight1 = weight1 >> 1;

          float tsdf2;
          int weight2;
          unpack_tsdf (*pos2, tsdf2, weight2);
          weight2 = weight2 >> 1;

          if(doDbgPrint)
              //printf("F1/F2, W1/W2: %f, %f, %d, %d; pos1/2-addr: %p, %p, %d; %p, %p, %d\n", tsdf1, tsdf2, weight1, weight2, 
              //(void*)pos, (void*)volume.ptr(), pos-volume.ptr(), (void*)pos2, (void*)volume2.ptr(), pos2-volume2.ptr());
              printf("F1/F2, W1/W2: 【%f, %f】, %d, %d;\n", tsdf1, tsdf2, weight1, weight2);

          float row[7]; //尝试改放循环内, 应无差别

          if(0 != weight1 && 0 != weight2 && tsdf1 != tsdf2){
              //+++++++++++++++PhiFuncGradients
              //参考 tsdf23normal_hack, 存疑: 不归一化, 不除 cell-sz 应该也行
              const float qnan = numeric_limits<float>::quiet_NaN();

              float3 dPhi_dX = make_float3(qnan, qnan, qnan);

              //const float m2mm = 1e3;

              float Fn, Fp;
              int Wn = 0, Wp = 0;
              unpack_tsdf (*(pos2 + elem_step2), Fn, Wn);
              unpack_tsdf (*(pos2 - elem_step2), Fp, Wp);
              Wn >>= 1; Wp >>= 1;
              if(doDbgPrint)
                  printf("\tz-Fn/Fp, Wn/Wp: %f, %f, %d, %d;\n", Fn, Fp, Wn, Wp);

              if(Wn != 0 && Wp != 0)
                  dPhi_dX.z = (Fn - Fp)/(2*cell_size.z); //csz in meters
                  //dPhi_dX.z = (Fn - Fp)/(2*cell_size.z*m2mm);
              else
                  continue;

              unpack_tsdf (*(pos2 + volume2.step/sizeof(short2) ), Fn, Wn);
              unpack_tsdf (*(pos2 - volume2.step/sizeof(short2) ), Fp, Wp);
              Wn >>= 1; Wp >>= 1;
              if(doDbgPrint)
                  printf("\ty-Fn/Fp, Wn/Wp: %f, %f, %d, %d;\n", Fn, Fp, Wn, Wp);

              if(Wn != 0 && Wp != 0)
                  dPhi_dX.y = (Fn - Fp)/(2*cell_size.y);
                  //dPhi_dX.y = (Fn - Fp)/(2*cell_size.y*m2mm);
              else
                  continue;

              unpack_tsdf (*(pos2 + 1), Fn, Wn);
              unpack_tsdf (*(pos2 - 1), Fp, Wp);
              Wn >>= 1; Wp >>= 1;
              if(doDbgPrint)
                  printf("\tx-Fn/Fp, Wn/Wp: %f, %f, %d, %d;\n", Fn, Fp, Wn, Wp);

              if(Wn != 0 && Wp != 0)
                  dPhi_dX.x = (Fn - Fp)/(2*cell_size.x);
                  //dPhi_dX.x = (Fn - Fp)/(2*cell_size.x*m2mm);
              else
                  continue;

              if(doDbgPrint)
                  printf("dPhi_dX.xyz: %f, %f, %f\n", dPhi_dX.x, dPhi_dX.y, dPhi_dX.z);

              //concatenate_matrix<<Eigen::MatrixXd::Identity(3,3),-selfCross(trans_point);
              //Eigen::Matrix<double, 1, 6> twist_partial = gradient * concatenate_matrix;
              //手写 1*3·3*6 = 1*6, 公式8 chain rule
              *(float3*)&row[0] = dPhi_dX;
              //推导存疑: g·u^= g^·u
              float3 pt_g; //in meters
#if 01 //就用 g-coo, 不用 cam-coo @2018-7-9 15:37:25
              pt_g.x = v_g_x;
              pt_g.y = v_g_y;
              pt_g.z = v_g_z;
#elif 1
              pt_g.x = v_x;
              pt_g.y = v_y;
              pt_g.z = v_z + Rcurr_inv.data[2].z * z_scaled;
#endif
              //pt_g*=m2mm;

              //*(float3*)&row[3] = cross(dPhi_dX, pt_g);
              //*(float3*)&row[3] *= -1;
              *(float3*)&row[3] = cross(pt_g, dPhi_dX); //dPhi*(-^pt)

              //row[6] = dot(tsdf1 - tsdf2 + dot(*(float6*)&row[0], xi_prev), *(float3*)&row[0]);
          }
          else
              //row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;
              continue;

          atomicAdd(&vxlValidCnt_device, 1);
          atomicAdd(&sumS2sErr_device, (tsdf1-tsdf2)*(tsdf1-tsdf2) );
//           atomicAdd(&tsdfDiffSum_device, tsdf2 - tsdf1);
//           atomicAdd(&tsdfAbsDiffSum_device, abs(tsdf2 - tsdf1));
//           printf("vg.xyz: %f, %f, %f; coo.xy:(%d, %d), F1/2: %f, %f, adiff: %f\n", 
//               v_g_x, v_g_y, v_g_z, coo.x, coo.y, tsdf1, tsdf2, abs(tsdf2 - tsdf1));
          int tid = Block::flattenedThreadId ();
          int total_tid = (blockIdx.x + gridDim.x * blockIdx.y) * (blockDim.x * blockDim.y) + tid;

          int shift = 0;

          //这里无论是否 0==z:
          #pragma unroll
          for (int i = 0; i < 6; ++i)        //rows
              #pragma unroll
              //for (int j = i; j < 7; ++j)          // cols + b
              for (int j = i; j < 6; ++j)          // cols, 不管最右列, 改放为最底行
                  gbuf.ptr (shift++)[ total_tid ] += row[i]*row[j]; //+=, NOT =

          //跟之前区别: gbuf:21+6 之前6是右列, 现在是最底行
          //这里 shift==21
          float tmp = tsdf1 - tsdf2 + dot(*(float6*)&row[0], xi_prev); //XI_C2G:=0, i.e. g2c
          //float tmp = tsdf2 - tsdf1 + dot(*(float6*)&row[0], xi_prev); //XI_C2G:=1
          float6 b = *(float6*)&row[0];
          b *= tmp;
          gbuf.ptr(shift++)[ total_tid ] += b.x;
          gbuf.ptr(shift++)[ total_tid ] += b.y;
          gbuf.ptr(shift++)[ total_tid ] += b.z;
          gbuf.ptr(shift++)[ total_tid ] += b.a;
          gbuf.ptr(shift++)[ total_tid ] += b.b;
          gbuf.ptr(shift++)[ total_tid ] += b.c;
        }//if-coo.xy >0 && <(rows,cols)
      }//for-z

    }//estimateCombined_s2s_kernel

    //虽然 volume 是 gcoo, 但是本v2 函数内, 各种坐标 v, n, 均转到 ref (即 k-1; tar 为 k) 坐标系中
    __global__ void
    estimateCombined_s2s_kernel_v2(const PtrStepSz<float> depthScaled, PtrStep<short2> volume, PtrStep<short2> volume2, 
        const float tranc_dist, const float eta, //s2s (delta, eta)
        const Mat33 Rcurr_inv, const float3 tcurr, 
        const Mat33 Rprev_inv, const float3 tprev, PtrStep<float> vmap_g_prev,  //改 f2m 用rcast 单视角的mod
        const float3 volume000_gcoo, float6 xi_prev, 
        const Intr intr, const float3 cell_size, 
        PtrStep<float> gbuf, 
        int3 vxlDbg)
    {
      int x = threadIdx.x + blockIdx.x * blockDim.x;
      int y = threadIdx.y + blockIdx.y * blockDim.y;

      //if (x >= VOLUME_X || y >= VOLUME_Y)
      if (x <= 1 || y <= 1 || x >= VOLUME_X-1 || y >= VOLUME_Y-1) //因 pos2 用到邻域算tsdf隐函数梯度
          return;

      //float v_g_x = (x + 0.5f) * cell_size.x - tcurr.x;
      //float v_g_y = (y + 0.5f) * cell_size.y - tcurr.y;
      //float v_g_z = (0 + 0.5f) * cell_size.z - tcurr.z;
#define F2M_NEW_USE_RCAST 0    //已验证, 根本来的 f2m 没多少区别, 在 long4-changjing 上 f240+ 仍然飘走 @2018-11-25 15:35:17
#if 0   //!F2M_NEW_USE_RCAST
      float v_g_x = (x + 0.5f) * cell_size.x + volume000_gcoo.x - tcurr.x;
      float v_g_y = (y + 0.5f) * cell_size.y + volume000_gcoo.y - tcurr.y;
      float v_g_z = (0 + 0.5f) * cell_size.z + volume000_gcoo.z - tcurr.z;
#else   //之前 f2m 在比如 long4-changjing 数据上漂移， 怀疑因为用了整个model, 尝试改用mod rcast 的视角相关方式 @2018-11-25 00:08:16
      float3 vg_true;
      vg_true.x = (x + 0.5f) * cell_size.x + volume000_gcoo.x;
      vg_true.y = (y + 0.5f) * cell_size.y + volume000_gcoo.y;
      vg_true.z = (0 + 0.5f) * cell_size.z + volume000_gcoo.z;

      float v_g_x = vg_true.x - tcurr.x;
      float v_g_y = vg_true.y - tcurr.y;
      float v_g_z = vg_true.z - tcurr.z;
#endif

      float v_g_part_norm = v_g_x * v_g_x + v_g_y * v_g_y;

      float v_x = (Rcurr_inv.data[0].x * v_g_x + Rcurr_inv.data[0].y * v_g_y + Rcurr_inv.data[0].z * v_g_z) * intr.fx;
      float v_y = (Rcurr_inv.data[1].x * v_g_x + Rcurr_inv.data[1].y * v_g_y + Rcurr_inv.data[1].z * v_g_z) * intr.fy;
      float v_z = (Rcurr_inv.data[2].x * v_g_x + Rcurr_inv.data[2].y * v_g_y + Rcurr_inv.data[2].z * v_g_z);

      float z_scaled = 0;

      float Rcurr_inv_0_z_scaled = Rcurr_inv.data[0].z * cell_size.z * intr.fx;
      float Rcurr_inv_1_z_scaled = Rcurr_inv.data[1].z * cell_size.z * intr.fy;

      float tranc_dist_inv = 1.0f / tranc_dist;

      //model /global
      short2* pos = volume.ptr (y) + x;
      int elem_step = volume.step * VOLUME_Y / sizeof(short2);

      //curr
      short2* pos2 = volume2.ptr (y) + x;
      int elem_step2 = volume2.step * VOLUME_Y / sizeof(short2);

      //float row[7]; //放循环外

      for (int z = 0; z < VOLUME_Z;
      //for (int z = 1; z < VOLUME_Z - 1; //错！导致 idx 偏了
           ++z,
           v_g_z += cell_size.z,
#if 1   //F2M_NEW_USE_RCAST
           vg_true.z += cell_size.z,
#endif
           z_scaled += cell_size.z,
           v_x += Rcurr_inv_0_z_scaled,
           v_y += Rcurr_inv_1_z_scaled,
           pos += elem_step,
           pos2 += elem_step2)
      {
        bool doDbgPrint = false;
        if(x > 0 && y > 0 && z > 0 //参数默认 000, 做无效值, 所以增加此检测
            && vxlDbg.x == x && vxlDbg.y == y && vxlDbg.z == z)
            doDbgPrint = true;
        
        //放到for最前面
        if(0 == z){ //for-loop-begin-set-0
            int tid = Block::flattenedThreadId ();
            int total_tid = (blockIdx.x + gridDim.x * blockIdx.y) * (blockDim.x * blockDim.y) + tid;

            int shift = 0;

            #pragma unroll
            for (int i = 0; i < 6; ++i)        //rows
                #pragma unroll
                for (int j = i; j < 7; ++j)          // cols + b
                    gbuf.ptr (shift++)[ total_tid ] = 0;
        }
        if(0 == z || VOLUME_Z -1 == z){
            if(doDbgPrint)
                printf("######################(0 == z || VOLUME_Z -1 == z)\n");
            continue;
        }

        float inv_z = 1.0f / (v_z + Rcurr_inv.data[2].z * z_scaled);
        if (inv_z < 0)
            continue;

        // project to current cam
        int2 coo =
        {
          __float2int_rn (v_x * inv_z + intr.cx),
          __float2int_rn (v_y * inv_z + intr.cy)
        };

        //if(doDbgPrint)
        //    printf("esti-s2s_kernel:: coo.xy:(%d, %d)\n", coo.x, coo.y);

        //↓-coo 范围判定, 貌似去掉也毫无变化, 为啥?    @2018-11-25 02:07:16
        if (coo.x >= 0 && coo.y >= 0 && coo.x < depthScaled.cols && coo.y < depthScaled.rows)         //6
        {
          float Dp_scaled = depthScaled.ptr (coo.y)[coo.x]; //meters 【【sdf、tsdf 本不需要再这样求, 因外部预计算了, 这里主要用作下面 ourlier 滤除  @2018-11-26 22:09:01

          //float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          //if(doDbgPrint){
          //    printf("Dp_scaled, sdf, tranc_dist, %f, %f, %f\n", Dp_scaled, sdf, tranc_dist);
          //    printf("coo.xy:(%d, %d)\n", coo.x, coo.y);
          //}

          //float sdf = Dp_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);

          ////if (Dp_scaled != 0 && sdf >= -tranc_dist) //meters
          //if (Dp_scaled != 0 && sdf >= -eta) //meters //比较 eta , 而非 delta (tdist)
          //{
          //  //read and unpack
          //  float tsdf_prev;
          //  int weight_prev;
          //  unpack_tsdf (*pos, tsdf_prev, weight_prev);
          //  //v17, 为配合 v17 用 w 二进制末位做标记位, 这里稍作修改: unpack 时 /2, pack 时 *2; @2018-1-22 02:01:27
          //  weight_prev = weight_prev >> 1;

          //  if(weight_prev == 0)
          //      continue;

          //  //↑--prev, ↓--curr
          //  float tsdf = fmin (1.0f, sdf * tranc_dist_inv);
          //  if(sdf < -tranc_dist)
          //      tsdf = -1.0f;

          //  const int Wrk = 1; //sdf>-eta ==> wrk=0 已经外层滤掉了, 不必再判断
          //  if(tsdf == tsdf_prev)
          //      continue;


          //vox 用 T_prev 转到 (i-1) cam-coo, 然后查找 vmap_g_prev
          //vg_true.x = v_g_x_true; //vg_true 定义在最前面
          //vg_true.y = v_g_y_true;
          //vg_true.z = v_g_z_true;
          float3 vprev_cam = Rprev_inv * (vg_true - tprev); //转到 prev cam-coo
          int2 coo_prev = //核心目的是对应点查找, 原文提到无需s2s优点之一是无需对应点查找, 实践发现通过 对应点dist对比, 滤除 outlier 很有必要 @2018-11-26 22:03:36
          {
              __float2int_rn (vprev_cam.x * intr.fx / vprev_cam.z + intr.cx),
              __float2int_rn (vprev_cam.y * intr.fy / vprev_cam.z + intr.cy)
          };
          if (!(coo_prev.x >= 0 && coo_prev.y >= 0 
              && coo_prev.x < depthScaled.cols && coo_prev.y < depthScaled.rows))
          {
              if(doDbgPrint){
                  printf("coo_prev_out_of_ROI; xy:= %d, %d\n", coo_prev.x, coo_prev.y);
                  //printf("Rpre")
              }

              continue;
          }

          float3 v_g_rcast;
          v_g_rcast.x = vmap_g_prev.ptr(coo_prev.y)[coo_prev.x];
          if (isnan (v_g_rcast.x)) //若 vmap_g_prev 对应位置无效值, 跳过
              continue;
          v_g_rcast.y = vmap_g_prev.ptr(coo_prev.y + depthScaled.rows)[coo_prev.x];
          v_g_rcast.z = vmap_g_prev.ptr(coo_prev.y + depthScaled.rows * 2)[coo_prev.x];

          //v_g_rcast = v_g_rcast -tcurr; //虽然 vg-rc 是 prev查表得到, 但此处不是 -tprev
          float depth_model_scaled = norm(v_g_rcast -tcurr); //虽然 vg-rc 是 prev查表得到, 但此处不是 -tprev
          if(depth_model_scaled == 0){ //理论上不可能进来
              printf("depth_model_scaled_eq_0; v_g_rcast: %f, %f, %f\n", v_g_rcast.x, v_g_rcast.y, v_g_rcast.z);
              continue;
          }

          //if(abs(depth_model_scaled - Dp_scaled) > 0.05){ //meters
          //    if(doDbgPrint)
          //        printf("abs(depth_model_scaled - Dp_scaled), outlier...\n");
          //    continue;
          //}
          //↑--改放到后面, 因为想看 outlier 时候 F1/F2 到底啥样

#if !F2M_NEW_USE_RCAST
          float tsdf1;
          int weight1;
          unpack_tsdf (*pos, tsdf1, weight1);
          //v17, 为配合 v17 用 w 二进制末位做标记位, 这里稍作修改: unpack 时 /2, pack 时 *2; @2018-1-22 02:01:27
          //weight1 = weight1 >> 1;
          weight1 = weight1 >> VOL1_FLAG_BIT_CNT; //后来标记位不止 1bit 了，尽管 s2s 融合用的独立的 integrateTsdfVolume_s2s, 但因为 march-cube 中统一 shift, 所以integ以及这里必须呼应
#else

          float tsdf1;
          int weight1;
          float sdf = depth_model_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm);
          if(doDbgPrint){
              printf("d_mod_scaled: %f, v_g_rcast: (%f, %f, %f); tcurr: (%f, %f, %f)\n", 
                  depth_model_scaled, v_g_rcast.x, v_g_rcast.y, v_g_rcast.z, tcurr.x, tcurr.y, tcurr.z);
              printf("sdf_F2M_NEW_USE_RCAST:= %f; d_mod_scaled: %f, vox_cam_dist: %f, sdf_again: %f\n", 
                  sdf, depth_model_scaled, sqrtf (v_g_z * v_g_z + v_g_part_norm),
                  depth_model_scaled - sqrtf (v_g_z * v_g_z + v_g_part_norm));
          }
          if(sdf > -eta){
              weight1 = 1;
              //tranc_dist_inv
              tsdf1 = fmin (1.0f, sdf * tranc_dist_inv);

              if(sdf < -tranc_dist)
                  tsdf1 = -1.0f;

              if(doDbgPrint){
                  float tsdf_unpack;
                  int weight_unpack;

                  unpack_tsdf (*pos, tsdf_unpack, weight_unpack);
                  weight_unpack = weight_unpack >> VOL1_FLAG_BIT_CNT;
                  printf("tsdf1: %f, tranc_dist: %f, eta: %f; (t, w)_unpack: %f, %d\n", 
                      tsdf1, tranc_dist, eta, tsdf_unpack, weight_unpack);
              }
          }
#endif
          float tsdf2;
          int weight2;
          unpack_tsdf (*pos2, tsdf2, weight2);
          weight2 = weight2 >> VOL1_FLAG_BIT_CNT;

          if(doDbgPrint){
              //printf("F1/F2, W1/W2: %f, %f, %d, %d; pos1/2-addr: %p, %p, %d; %p, %p, %d\n", tsdf1, tsdf2, weight1, weight2, 
              //(void*)pos, (void*)volume.ptr(), pos-volume.ptr(), (void*)pos2, (void*)volume2.ptr(), pos2-volume2.ptr());

              //printf("F1/F2, W1/W2: 【%f, %f】, %d, %d; condi_BEFORE: %d\n", 
              //    tsdf1, tsdf2, weight1, weight2,
              //    (0 != weight1 && 0 != weight2 && tsdf1 != tsdf2)
              //    );

              //printf("\t BEFORE:--w1: %d, w2: %d, t1: %f, t2: %f; condi: %d\n",
              //    weight1, weight2, tsdf1, tsdf2,
              //    (0 != weight1 && 0 != weight2 && tsdf1 != tsdf2)
              //    );

          }

          if(abs(depth_model_scaled - Dp_scaled) > 0.05){ //meters
              if(doDbgPrint)
                  printf("abs(depth_model_scaled - Dp_scaled), outlier...\n");
              continue;
          }

          float row[7]; //尝试改放循环内, 应无差别

          if(0 != weight1 && 0 != weight2 && tsdf1 != tsdf2){
              //+++++++++++++++PhiFuncGradients
              //参考 tsdf23normal_hack, 存疑: 不归一化, 不除 cell-sz 应该也行
              const float qnan = numeric_limits<float>::quiet_NaN();

              float3 dPhi_dX = make_float3(qnan, qnan, qnan);

              //const float m2mm = 1e3;

              float Fn, Fp;
              int Wn = 0, Wp = 0;
              unpack_tsdf (*(pos2 + elem_step2), Fn, Wn);
              unpack_tsdf (*(pos2 - elem_step2), Fp, Wp);
              //Wn >>= 1; Wp >>= 1;
              Wn >>= VOL1_FLAG_BIT_CNT; Wp >>= VOL1_FLAG_BIT_CNT;
              if(doDbgPrint)
                  printf("\tz-Fn/Fp, Wn/Wp: %f, %f, %d, %d;\n", Fn, Fp, Wn, Wp);

              if(Wn != 0 && Wp != 0)
                  dPhi_dX.z = (Fn - Fp)/(2*cell_size.z); //csz in meters
                  //dPhi_dX.z = (Fn - Fp)/(2*cell_size.z*m2mm);
              else
                  continue;

              unpack_tsdf (*(pos2 + volume2.step/sizeof(short2) ), Fn, Wn);
              unpack_tsdf (*(pos2 - volume2.step/sizeof(short2) ), Fp, Wp);
              //Wn >>= 1; Wp >>= 1;
              Wn >>= VOL1_FLAG_BIT_CNT; Wp >>= VOL1_FLAG_BIT_CNT;
              if(doDbgPrint)
                  printf("\ty-Fn/Fp, Wn/Wp: %f, %f, %d, %d;\n", Fn, Fp, Wn, Wp);

              if(Wn != 0 && Wp != 0)
                  dPhi_dX.y = (Fn - Fp)/(2*cell_size.y);
                  //dPhi_dX.y = (Fn - Fp)/(2*cell_size.y*m2mm);
              else
                  continue;

              unpack_tsdf (*(pos2 + 1), Fn, Wn);
              unpack_tsdf (*(pos2 - 1), Fp, Wp);
              //Wn >>= 1; Wp >>= 1;
              Wn >>= VOL1_FLAG_BIT_CNT; Wp >>= VOL1_FLAG_BIT_CNT;
              if(doDbgPrint)
                  printf("\tx-Fn/Fp, Wn/Wp: %f, %f, %d, %d;\n", Fn, Fp, Wn, Wp);

              if(Wn != 0 && Wp != 0)
                  dPhi_dX.x = (Fn - Fp)/(2*cell_size.x);
                  //dPhi_dX.x = (Fn - Fp)/(2*cell_size.x*m2mm);
              else
                  continue;


              //if(doDbgPrint)
              //    printf(">>>>>>dPhi_dX.xyz: %f, %f, %f\n", dPhi_dX.x, dPhi_dX.y, dPhi_dX.z);
              dPhi_dX = Rcurr_inv * dPhi_dX; //use local (cam-coo)
              if(doDbgPrint)
                  printf("<<<<<dPhi_dX.xyz: %f, %f, %f\n", dPhi_dX.x, dPhi_dX.y, dPhi_dX.z);

              //concatenate_matrix<<Eigen::MatrixXd::Identity(3,3),-selfCross(trans_point);
              //Eigen::Matrix<double, 1, 6> twist_partial = gradient * concatenate_matrix;
              //手写 1*3·3*6 = 1*6, 公式8 chain rule
              *(float3*)&row[0] = dPhi_dX;
              //推导存疑: g·u^= g^·u
              float3 pt_g; //in meters
#if 0 //就用 g-coo, 不用 cam-coo @2018-7-9 15:37:25
              pt_g.x = v_g_x;
              pt_g.y = v_g_y;
              pt_g.z = v_g_z;
#elif 1 //use local (cam-coo)
              pt_g.x = v_x / intr.fx; //因为前面的 vx 带了 *fx 乘数, 不是真的物理量
              pt_g.y = v_y / intr.fy;
              pt_g.z = v_z + Rcurr_inv.data[2].z * z_scaled;

              //if(doDbgPrint)
              //    printf("\tpt_g.xyz: %f, %f, %f\n", pt_g.x, pt_g.y, pt_g.z);
#endif
              //pt_g*=m2mm;

              //*(float3*)&row[3] = cross(dPhi_dX, pt_g);
              //*(float3*)&row[3] *= -1;
              *(float3*)&row[3] = cross(pt_g, dPhi_dX); //dPhi*(-^pt)

              //row[6] = dot(tsdf1 - tsdf2 + dot(*(float6*)&row[0], xi_prev), *(float3*)&row[0]);
          }
          else{
              //row[0] = row[1] = row[2] = row[3] = row[4] = row[5] = row[6] = 0.f;
              if(doDbgPrint){
                  printf("\t w1_w2_invalid_or_t1_eq_t2, w1: %d, w2: %d, t1: %f, t2: %f; condi: %d\n",
                      weight1, weight2, tsdf1, tsdf2,
                      (0 != weight1 && 0 != weight2 && tsdf1 != tsdf2)
                      );
              }
              continue;
          }
          atomicAdd(&vxlValidCnt_device, 1);
          atomicAdd(&sumS2sErr_device, (tsdf1-tsdf2)*(tsdf1-tsdf2) );
          //atomicAdd(&tsdfDiffSum_device, tsdf2 - tsdf1);
          //atomicAdd(&tsdfAbsDiffSum_device, abs(tsdf2 - tsdf1));
//           printf("vg.xyz: %f, %f, %f; coo.xy:(%d, %d), F1/2: %f, %f, adiff: %f\n", 
//               v_g_x, v_g_y, v_g_z, coo.x, coo.y, tsdf1, tsdf2, abs(tsdf2 - tsdf1));
          int tid = Block::flattenedThreadId ();
          int total_tid = (blockIdx.x + gridDim.x * blockIdx.y) * (blockDim.x * blockDim.y) + tid;

          int shift = 0;

          //这里无论是否 0==z:
          #pragma unroll
          for (int i = 0; i < 6; ++i)        //rows
              #pragma unroll
              //for (int j = i; j < 7; ++j)          // cols + b
              for (int j = i; j < 6; ++j)          // cols, 不管最右列, 改放为最底行
                  gbuf.ptr (shift++)[ total_tid ] += row[i]*row[j]; //+=, NOT =

          //跟之前区别: gbuf:21+6 之前6是右列, 现在是最底行
          //这里 shift==21
          //float tmp = tsdf1 - tsdf2 + dot(*(float6*)&row[0], xi_prev); //g2c, i.e., XI_C2G:=0
          float tmp = tsdf2 - tsdf1 + dot(*(float6*)&row[0], xi_prev); //XI_C2G:=1
          float6 b = *(float6*)&row[0];
          b *= tmp;
          gbuf.ptr(shift++)[ total_tid ] += b.x;
          gbuf.ptr(shift++)[ total_tid ] += b.y;
          gbuf.ptr(shift++)[ total_tid ] += b.z;
          gbuf.ptr(shift++)[ total_tid ] += b.a;
          gbuf.ptr(shift++)[ total_tid ] += b.b;
          gbuf.ptr(shift++)[ total_tid ] += b.c;
        }//if-coo.xy >0 && <(rows,cols)
      }//for-z

    }//estimateCombined_s2s_kernel_v2

  }//namespace device
}//namespace pcl


//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void
pcl::device::estimateCombined (const Mat33& Rcurr, const float3& tcurr, 
                               const MapArr& vmap_curr, const MapArr& nmap_curr, 
                               const Mat33& Rprev_inv, const float3& tprev, const Intr& intr,
                               const MapArr& vmap_g_prev, const MapArr& nmap_g_prev, 
                               float distThres, float angleThres,
                               DeviceArray2D<float_type>& gbuf, DeviceArray<float_type>& mbuf, 
                               float_type* matrixA_host, float_type* vectorB_host)
{
  int cols = vmap_curr.cols ();
  int rows = vmap_curr.rows () / 3;
  dim3 block (Combined::CTA_SIZE_X, Combined::CTA_SIZE_Y);
  dim3 grid (1, 1, 1);
  grid.x = divUp (cols, block.x);
  grid.y = divUp (rows, block.y);

  /*
  Combined cs;

  cs.Rcurr = Rcurr;
  cs.tcurr = tcurr;

  cs.vmap_curr = vmap_curr;
  cs.nmap_curr = nmap_curr;

  cs.Rprev_inv = Rprev_inv;
  cs.tprev = tprev;

  cs.intr = intr;

  cs.vmap_g_prev = vmap_g_prev;
  cs.nmap_g_prev = nmap_g_prev;

  cs.distThres = distThres;
  cs.angleThres = angleThres;

  cs.cols = cols;
  cs.rows = rows;

//////////////////////////////

  mbuf.create (TranformReduction::TOTAL);
  if (gbuf.rows () != TranformReduction::TOTAL || gbuf.cols () < (int)(grid.x * grid.y))
    gbuf.create (TranformReduction::TOTAL, grid.x * grid.y);

  cs.gbuf = gbuf;

  combinedKernel<<<grid, block>>>(cs);
  cudaSafeCall ( cudaGetLastError () );
  //cudaSafeCall(cudaDeviceSynchronize());

  //printFuncAttrib(combinedKernel);

  TranformReduction tr;
  tr.gbuf = gbuf;
  tr.length = grid.x * grid.y;
  tr.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());
  */
  Combined2 cs2;

  cs2.Rcurr = Rcurr;
  cs2.tcurr = tcurr;

  cs2.vmap_curr = vmap_curr;
  cs2.nmap_curr = nmap_curr;

  cs2.Rprev_inv = Rprev_inv;
  cs2.tprev = tprev;

  cs2.intr = intr;

  cs2.vmap_g_prev = vmap_g_prev;
  cs2.nmap_g_prev = nmap_g_prev;

  cs2.distThres = distThres;
  cs2.angleThres = angleThres;

  cs2.cols = cols;
  cs2.rows = rows;

  cs2.gbuf = gbuf;

  combinedKernel2<<<grid, block>>>(cs2);
  cudaSafeCall ( cudaGetLastError () );

  //zc: dbg *gbuf*
#if 0
  const int pxNUM = 640 * 480;
  //float_type gbuf_host[27];//*640*480]; //31MB 导致栈内存溢出, 改用 new
  float_type *gbuf_host = new float_type[27*pxNUM];
  gbuf.download(gbuf_host, pxNUM*sizeof(float_type));
  for(int i=0; i<27; i++){
	  float sum = 0;
	  for(int j=0; j<pxNUM; j++){
		  sum += gbuf_host[i*pxNUM + j];
	  }
	  printf("gbuf_host::sum(%d):=%f\n", i, sum);
  }
#endif

  TranformReduction tr2;
  tr2.gbuf = gbuf;
  tr2.length = cols * rows;
  tr2.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr2);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());

  float_type host_data[TranformReduction::TOTAL];
  mbuf.download (host_data);

  int shift = 0;
  for (int i = 0; i < 6; ++i)  //rows
    for (int j = i; j < 7; ++j)    // cols + b
    {
      float_type value = host_data[shift++];
      if (j == 6)       // vector b
        vectorB_host[i] = value;
      else
        matrixA_host[j * 6 + i] = matrixA_host[i * 6 + j] = value;
    }
}

float pcl::device::tsdf_diff_sum_host_;
float pcl::device::tsdf_abs_diff_sum_host_;

void
pcl::device::estimateCombined_s2s(const PtrStepSz<ushort>& depth_raw, const Intr& intr, const float3& volume_size, 
        const Mat33& Rcurr_inv, const float3& tcurr, 
        const Mat33& Rprev_inv, const float3& tprev, PtrStep<float> vmap_g_prev,    //F2M_NEW_USE_RCAST @2018-11-25 00:47:27
        const float3& volume000_gcoo, const float6& xi_prev, 
        float tranc_dist, PtrStep<short2> volume, PtrStep<short2> volume2,
        //float delta, 
        float eta, //s2s TSDF param, delta is tranc_dist, 
        DeviceArray2D<float>& gbuf, DeviceArray<float>& mbuf, float* matrixA_host, float* vectorB_host,
        DeviceArray2D<float>& depthScaled, int &vxlValidCnt, float &sum_s2s_err, int3 vxlDbg /*= int3()*/)
{
    //pcl::console::TicToc tt;
    clock_t begt = clock();
#if 0
  depthScaled.create (depth_raw.rows, depth_raw.cols);

  dim3 block_scale (32, 8);
  dim3 grid_scale (divUp (depth_raw.cols, block_scale.x), divUp (depth_raw.rows, block_scale.y));

  //scales depth along ray and converts mm -> meters. 
  scaleDepth<<<grid_scale, block_scale>>>(depth_raw, depthScaled, intr);
  cudaSafeCall ( cudaGetLastError () );

#elif 0 //移到 KinfuTracker::s2sOdometry 最外层
    scaleDepthDevice(depth_raw, intr, depthScaled);
#endif
  //↓--也放到外面, 放到 initVrayPrevVolume(tsdf_volume_->volume2nd_); 之后 @2018-11-25 16:39:26
//   integrateTsdfVolume_s2s(/*depth_raw,*/ intr, volume_size, Rcurr_inv, tcurr,
//       volume000_gcoo, tranc_dist, eta, volume2, depthScaled, vxlDbg); //这里 set vol-2

  //printf("integrateTsdfVolume_s2s-volume2: %dms\n", clock()-begt); 
  //tt.toc_print();

  float3 cell_size;
  cell_size.x = volume_size.x / VOLUME_X;
  cell_size.y = volume_size.y / VOLUME_Y;
  cell_size.z = volume_size.z / VOLUME_Z;

  //dim3 block(Tsdf::CTA_SIZE_X, Tsdf::CTA_SIZE_Y);
  dim3 block (16, 16);
  dim3 grid (divUp (VOLUME_X, block.x), divUp (VOLUME_Y, block.y));

  //cudaSafeCall(cudaMemset(&vxlValidCnt_device, 0, sizeof(int)) ); //×

  int dummy0 = 0;
  cudaSafeCall(cudaMemcpyToSymbol(vxlValidCnt_device, &dummy0, sizeof(int)) );
  float dummy0f = 0.f;
  cudaSafeCall(cudaMemcpyToSymbol(sumS2sErr_device, &dummy0f, sizeof(float)) );
//   cudaSafeCall(cudaMemcpyToSymbol(tsdfDiffSum_device, &dummy0f, sizeof(float)) );
//   cudaSafeCall(cudaMemcpyToSymbol(tsdfAbsDiffSum_device, &dummy0f, sizeof(float)) );

  //estimateCombined_s2s_kernel<<<grid, block>>>(depthScaled, volume, volume2,
  estimateCombined_s2s_kernel_v2<<<grid, block>>>(depthScaled, volume, volume2,
      tranc_dist, eta, Rcurr_inv, tcurr, 
      Rprev_inv, tprev, vmap_g_prev, //F2M_NEW_USE_RCAST @2018-11-25 00:54:42
      volume000_gcoo, xi_prev, 
      intr, cell_size, gbuf, 
      vxlDbg);    

  cudaSafeCall(cudaMemcpyFromSymbol(&vxlValidCnt, vxlValidCnt_device, sizeof(vxlValidCnt)) );
  cudaSafeCall(cudaMemcpyFromSymbol(&sum_s2s_err, sumS2sErr_device, sizeof(sum_s2s_err)) );
//   cudaSafeCall(cudaMemcpyFromSymbol(&tsdf_diff_sum_host_, tsdfDiffSum_device, sizeof(tsdf_diff_sum_host_)) );
//   cudaSafeCall(cudaMemcpyFromSymbol(&tsdf_abs_diff_sum_host_, tsdfAbsDiffSum_device, sizeof(tsdf_abs_diff_sum_host_)) );

  TranformReduction tr2;
  tr2.gbuf = gbuf;
  //tr2.length = cols * rows;
  tr2.length = VOLUME_X * VOLUME_Y;
  tr2.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr2);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());

  float_type host_data[TranformReduction::TOTAL];
  mbuf.download (host_data);

//   int shift = 0;
//   for (int i = 0; i < 6; ++i)  //rows
//       for (int j = i; j < 7; ++j)    // cols + b
//       {
//           float_type value = host_data[shift++];
//           if (j == 6)       // vector b
//               vectorB_host[i] = value;
//           else
//               matrixA_host[j * 6 + i] = matrixA_host[i * 6 + j] = value;
//       }
  int shift = 0;
  for (int i = 0; i < 6; ++i)  //rows
      //for (int j = i; j < 7; ++j)    // cols + b
      for (int j = i; j < 6; ++j)    // cols
          matrixA_host[j * 6 + i] = matrixA_host[i * 6 + j] = host_data[shift++];
  
  for (int i = 0; i < 6; ++i)  //最底行, 最后六个值
      vectorB_host[i] = host_data[shift++];
}//estimateCombined_s2s

void
pcl::device::scaleDepthDevice(const PtrStepSz<ushort>& depth_raw, const Intr& intr, DeviceArray2D<float>& depthScaled){
    //pcl::console::TicToc tt;
    clock_t begt = clock();
    depthScaled.create (depth_raw.rows, depth_raw.cols);

    dim3 block_scale (32, 8);
    dim3 grid_scale (divUp (depth_raw.cols, block_scale.x), divUp (depth_raw.rows, block_scale.y));

    //scales depth along ray and converts mm -> meters. 
    scaleDepth<<<grid_scale, block_scale>>>(depth_raw, depthScaled, intr);
    cudaSafeCall ( cudaGetLastError () );

    //printf("\t>>>-------scaleDepthDevice-time: %dms\n", clock()-begt); //0ms

}//scaleDepthDevice

void
pcl::device::scaleDepthDevice(const MapArr& vmap_g, const float3& tvec, const Intr& intr, DeviceArray2D<float>& depthScaled){
    //pcl::console::TicToc tt;

    //clock_t begt = clock();
    int cols = vmap_g.cols ();
    int rows = vmap_g.rows () / 3;
    //printf("cc,rr@scaleDepthDevice_vmap: %d, %d\n", cols, rows); //640, 480 没问题

    depthScaled.create (rows, cols);

    dim3 block_scale (32, 8);
    dim3 grid_scale (divUp (cols, block_scale.x), divUp (rows, block_scale.y));

    //scales depth along ray and converts mm -> meters. 
    scaleDepth_vmap<<<grid_scale, block_scale>>>(vmap_g, tvec, depthScaled, intr);
    cudaSafeCall ( cudaGetLastError () );

    //printf("\t>>>-------scaleDepthDevice-time: %dms\n", clock()-begt); //0ms

}//scaleDepthDevice-vmap版

//zc: nmap 惩罚项专用, 与 estimateCombined 区别是 combinedKernel2 调用链非 operator() @2017-6-1 13:11:25
void
pcl::device::estimateCombined_nmap (const Mat33& Rcurr, const float3& tcurr, 
                               const MapArr& vmap_curr, const MapArr& nmap_curr, 
                               const Mat33& Rprev_inv, const float3& tprev, const Intr& intr,
                               const MapArr& vmap_g_prev, const MapArr& nmap_g_prev, 
                               float distThres, float angleThres,
                               DeviceArray2D<float_type>& gbuf, DeviceArray<float_type>& mbuf, 
                               float_type* matrixA_host, float_type* vectorB_host)
{
  int cols = vmap_curr.cols ();
  int rows = vmap_curr.rows () / 3;
  dim3 block (Combined::CTA_SIZE_X, Combined::CTA_SIZE_Y);
  dim3 grid (1, 1, 1);
  grid.x = divUp (cols, block.x);
  grid.y = divUp (rows, block.y);

  /*
  Combined cs;

  cs.Rcurr = Rcurr;
  cs.tcurr = tcurr;

  cs.vmap_curr = vmap_curr;
  cs.nmap_curr = nmap_curr;

  cs.Rprev_inv = Rprev_inv;
  cs.tprev = tprev;

  cs.intr = intr;

  cs.vmap_g_prev = vmap_g_prev;
  cs.nmap_g_prev = nmap_g_prev;

  cs.distThres = distThres;
  cs.angleThres = angleThres;

  cs.cols = cols;
  cs.rows = rows;

//////////////////////////////

  mbuf.create (TranformReduction::TOTAL);
  if (gbuf.rows () != TranformReduction::TOTAL || gbuf.cols () < (int)(grid.x * grid.y))
    gbuf.create (TranformReduction::TOTAL, grid.x * grid.y);

  cs.gbuf = gbuf;

  combinedKernel<<<grid, block>>>(cs);
  cudaSafeCall ( cudaGetLastError () );
  //cudaSafeCall(cudaDeviceSynchronize());

  //printFuncAttrib(combinedKernel);

  TranformReduction tr;
  tr.gbuf = gbuf;
  tr.length = grid.x * grid.y;
  tr.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());
  */
  Combined2 cs2;

  cs2.Rcurr = Rcurr;
  cs2.tcurr = tcurr;

  cs2.vmap_curr = vmap_curr;
  cs2.nmap_curr = nmap_curr;

  cs2.Rprev_inv = Rprev_inv;
  cs2.tprev = tprev;

  cs2.intr = intr;

  cs2.vmap_g_prev = vmap_g_prev;
  cs2.nmap_g_prev = nmap_g_prev;

  cs2.distThres = distThres;
  cs2.angleThres = angleThres;

  cs2.cols = cols;
  cs2.rows = rows;

  cs2.gbuf = gbuf;

  //combinedKernel2<<<grid, block>>>(cs2);
  combinedKernel2_nmap<<<grid, block>>>(cs2); //zc
  
  cudaSafeCall ( cudaGetLastError () );

  //zc: dbg *gbuf*
#if 0
  const int pxNUM = 640 * 480;
  //float_type gbuf_host[27];//*640*480]; //31MB 导致栈内存溢出, 改用 new
  float_type *gbuf_host = new float_type[27*pxNUM];
  gbuf.download(gbuf_host, pxNUM*sizeof(float_type));
  for(int i=0; i<27; i++){
	  float sum = 0;
	  for(int j=0; j<pxNUM; j++){
		  sum += gbuf_host[i*pxNUM + j];
	  }
	  printf("gbuf_host::sum(%d):=%f\n", i, sum);
  }
#endif

  TranformReduction tr2;
  tr2.gbuf = gbuf;
  tr2.length = cols * rows;
  tr2.output = mbuf;

  //TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr2);
  TransformEstimatorKernel2<<<9, TranformReduction::CTA_SIZE>>>(tr2); //9=3x3, 原 TranformReduction::TOTAL=27
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());

  float_type host_data[TranformReduction::TOTAL];
  mbuf.download (host_data);

#if 0   //用原 TranformReduction::TOTAL=27
  int shift = 0;
  for (int i = 0; i < 6; ++i)  //rows
    for (int j = i; j < 7; ++j)    // cols + b
    {
      float_type value = host_data[shift++];
      if (j == 6)       // vector b
        vectorB_host[i] = value;
      else
        matrixA_host[j * 6 + i] = matrixA_host[i * 6 + j] = value;
    }
#elif 1 //改 matrixA_host 仅用前 3x3 (本是 6x6) 
  int shift = 0;
  for(int i=0; i<3; ++i)  //rows
    for(int j=0; j<3; ++j){
      float_type value = host_data[shift++];
      matrixA_host[i * 6 + j] = value;
    }

    //↓-这样错, 因为 matrixA_host 仍是 66 矩阵
//   for(int i=0; i<9; ++i)
//       matrixA_host[i] = host_data[i];
#endif
}//estimateCombined_nmap

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////
void
pcl::device::estimateCombinedPrevSpace (const Mat33& Rcurr, const float3& tcurr, 
                               const MapArr& vmap_curr, const MapArr& nmap_curr, 
                               const Mat33& Rprev_inv, const float3& tprev, const Intr& intr,
                               const MapArr& vmap_g_prev, const MapArr& nmap_g_prev, 
                               float distThres, float angleThres,
                               DeviceArray2D<float_type>& gbuf, DeviceArray<float_type>& mbuf, 
                               float_type* matrixA_host, float_type* vectorB_host)
{
  int cols = vmap_curr.cols ();
  int rows = vmap_curr.rows () / 3;
  dim3 block (Combined::CTA_SIZE_X, Combined::CTA_SIZE_Y);
  dim3 grid (1, 1, 1);
  grid.x = divUp (cols, block.x);
  grid.y = divUp (rows, block.y);

  CombinedPrevSpace cs3;

  cs3.Rcurr = Rcurr;
  cs3.tcurr = tcurr;

  cs3.vmap_curr = vmap_curr;
  cs3.nmap_curr = nmap_curr;

  cs3.Rprev_inv = Rprev_inv;
  cs3.tprev = tprev;

  cs3.intr = intr;

  cs3.vmap_g_prev = vmap_g_prev;
  cs3.nmap_g_prev = nmap_g_prev;

  cs3.distThres = distThres;
  cs3.angleThres = angleThres;

  cs3.cols = cols;
  cs3.rows = rows;

  cs3.gbuf = gbuf;

  combinedKernelPrevSpace<<<grid, block>>>(cs3);
  cudaSafeCall ( cudaGetLastError () );

  TranformReduction tr2;
  tr2.gbuf = gbuf;
  tr2.length = cols * rows;
  tr2.output = mbuf;

  TransformEstimatorKernel2<<<TranformReduction::TOTAL, TranformReduction::CTA_SIZE>>>(tr2);
  cudaSafeCall (cudaGetLastError ());
  cudaSafeCall (cudaDeviceSynchronize ());

  float_type host_data[TranformReduction::TOTAL];
  mbuf.download (host_data);

  int shift = 0;
  for (int i = 0; i < 6; ++i)  //rows
    for (int j = i; j < 7; ++j)    // cols + b
    {
      float_type value = host_data[shift++];
      if (j == 6)       // vector b
        vectorB_host[i] = value;
      else
        matrixA_host[j * 6 + i] = matrixA_host[i * 6 + j] = value;
    }
}
