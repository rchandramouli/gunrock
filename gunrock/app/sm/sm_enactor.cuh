// ----------------------------------------------------------------------------
// Gunrock -- High-Performance Graph Primitives on GPU
// ----------------------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------------------

/**
 * @file sm_enactor.cuh
 * @brief Primitive problem enactor
 */

#pragma once

#include <gunrock/util/kernel_runtime_stats.cuh>
#include <gunrock/util/test_utils.cuh>

#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/advance/kernel_policy.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>
#include <gunrock/oprtr/filter/kernel_policy.cuh>

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/sm/sm_problem.cuh>
#include <gunrock/app/sm/sm_functor.cuh>

namespace gunrock {
namespace app {
namespace sm {

/**
 * @brief SM Primitive enactor class.
 *
 * @tparam _Problem
 * @tparam INSTRUMWENT Boolean indicate collect per-CTA clock-count statistics
 * @tparam _DEBUG
 * @tparam _SIZE_CHECK
 */
template<
    typename _Problem,
    bool _INSTRUMENT,
    bool _DEBUG,
    bool _SIZE_CHECK>
class SMEnactor : public EnactorBase<typename _Problem::SizeT, _DEBUG, _SIZE_CHECK> {
 protected:

    /**
     * @brief Prepare the enactor for kernel call.
     *
     * @param[in] problem Problem object holds both graph and primitive data.
     *
     * \return cudaError_t object indicates the success of all CUDA functions.
     */
    template <typename ProblemData>
    cudaError_t Setup(ProblemData *problem) {
        typedef typename ProblemData::SizeT    SizeT;
        typedef typename ProblemData::VertexId VertexId;

        cudaError_t retval = cudaSuccess;
/*
        // graph slice
        GraphSlice<SizeT, VertexId, Value>*
		graph_slice = problem->graph_slices[0];
	// data slice
	typename Problem::DataSlice*
		data_slice = problem->data_slices[0];
*/
        return retval;
    }

 public:
    typedef _Problem                   Problem;
    typedef typename Problem::SizeT    SizeT;
    typedef typename Problem::VertexId VertexId;
    typedef typename Problem::Value    Value;
    static const bool INSTRUMENT = _INSTRUMENT;
    static const bool DEBUG      = _DEBUG;
    static const bool SIZE_CHECK = _SIZE_CHECK;
   
    /**
     * @brief Primitive Constructor.
     *
     * @param[in] gpu_idx GPU indices
     */
    SMEnactor(int *gpu_idx):
        EnactorBase<typename _Problem::SizeT, _DEBUG, _SIZE_CHECK>(
            EDGE_FRONTIERS, 1, gpu_idx) {}

    /**
     * @brief Primitive Destructor
     */
    virtual ~SMEnactor() {}

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief Obtain statistics the primitive enacted.
     * @param[out] num_iterations Number of iterations (BSP super-steps).
     */
    template <typename VertexId>
    void GetStatistics(VertexId &num_iterations) {
        cudaThreadSynchronize();
        num_iterations = this->enactor_stats.iteration;
        // TODO: code to extract more statistics if necessary
    }

    /** @} */

    /**
     * @brief Enacts computing on the specified graph.
     *
     * @tparam AdvanceKernelPolicy Kernel policy for advance operator.
     * @tparam FilterKernelPolicy Kernel policy for filter operator.
     * @tparam Problem Problem type.
     *
     * @param[in] context CudaContext pointer for ModernGPU APIs
     * @param[in] problem Problem object.
     * @param[in] max_grid_size Max grid size for kernel calls.
     *
     * \return cudaError_t object indicates the success of all CUDA functions.
     */
    template <
        typename AdvanceKernelPolicy,
        typename FilterKernelPolicy,
        typename Problem >
    cudaError_t EnactSM(
        ContextPtr  context,
        Problem*    problem,
        int         max_grid_size = 0) {
        typedef typename Problem::SizeT  SizeT;
	typedef typename Problem::Value  Value;
        typedef typename Problem::VertexId VertexId;

        // Define functors used in SMProblem
        typedef SMInitFunctor<VertexId, SizeT, Value, Problem> SMInitFunctor;
      //  typedef EdgeWeightFunctor<VertexId, SizeT, Value, SMProblem> EdgeWeightFunctor;
        typedef PruneFunctor<VertexId, SizeT, Value, Problem> PruneFunctor;

        cudaError_t retval = cudaSuccess;

	FrontierAttribute<SizeT>
            *frontier_attribute = &this->frontier_attribute[0];
        EnactorStats *enactor_stats = &this->enactor_stats[0];
        typename Problem::DataSlice *data_slice = problem->data_slices[0];
	util::DoubleBuffer<SizeT, VertexId, Value>*
            frontier_queue     = &data_slice->frontier_queues[0];
        util::CtaWorkProgressLifetime *work_progress = &this->work_progress[0];
        cudaStream_t stream = data_slice->streams[0];

        do {
	    SizeT* d_scanned_edges = NULL;

            if(DEBUG) {
                printf("Iteration, Edge map queue, Vertex map queue\n");
                printf("0");
            }
            fflush(stdout);

	    // Lazy Initialization
	    if (retval = Setup(problem)) break;
	    
	    if (retval = EnactorBase<typename _Problem::SizeT,
				     _DEBUG, _SIZE_CHECK>::Setup(
					    problem,
				  	    max_grid_size,
					    AdvanceKernelPolicy::CTA_OCCUPANCY,
					    FilterKernelPolicy::CTA_OCCUPANCY)) break;

	    // Single-gpu graph slice
	    GraphSlice<SizeT, VertexId, Value> *graph_slice = problem->graph_slices[0];
	    typename Problem::DataSlice *d_data_slice = problem->d_data_slices[0];

	    if (AdvanceKernelPolicy::ADVANCE_MODE == gunrock::oprtr::advance::LB)
      	    {
        	if (retval = util::GRError(cudaMalloc((void**)&d_scanned_edges,
         	 graph_slice->edges * sizeof(unsigned int)),
          	"SMProblem cudaMalloc d_scanned_edges failed",
         	 __FILE__, __LINE__)) return retval;
     	    }

	    frontier_attribute->queue_length = graph_slice->nodes;
	    frontier_attribute->queue_index = 0; // work queue index
	    frontier_attribute->selector = 0;
	    frontier_attribute->queue_reset = true;

	    // Initial filtering based on node labels and degrees
/*
	    oprtr::filter::Kernel<FilterKernelPolicy, Problem, SMInitFunctor>
		<<<enactor_stats->filter_grid_size, FilterKernelPolicy::THREADS>>>(
			0,
			frontier_attribute.queue_reset,
			frontier_attribute.queue_index,
			enactor_stats.num_gpus,
			frontier_attribute.queue_length,
			d_done,
			graph_slice->frontier_queues.d_keys[frontier_attribute.selector],
			NULL,
			NULL,
			data_slice,
			NULL,
			work_progress,
			graph_slice->frontier_elements[frontier_attribute.selector],
			graph_slice->frontier_elements[frontier_attribute.selector^1],
			enactor_stats.filter_kernel_stats,
			false);
*/
	  oprtr::filter::Kernel<FilterKernelPolicy, Problem, SMInitFunctor><<<
                enactor_stats->filter_grid_size,
                FilterKernelPolicy::THREADS, 0, stream>>>(
                enactor_stats->iteration + 1,
                frontier_attribute->queue_reset,
                frontier_attribute->queue_index,
                frontier_attribute->queue_length,
                frontier_queue->keys[frontier_attribute->selector  ].GetPointer(util::DEVICE),
                NULL,
                frontier_queue->keys[frontier_attribute->selector^1].GetPointer(util::DEVICE),
                d_data_slice,
                NULL,
                work_progress[0],
                frontier_queue->keys[frontier_attribute->selector  ].GetSize(),
                frontier_queue->keys[frontier_attribute->selector^1].GetSize(),
                enactor_stats->filter_kernel_stats);


	    if(DEBUG && (retval = util::GRError(cudaThreadSynchronize(), 
		"Initial Filtering failed", __FILE__, __LINE__))) break;
//	    enactor_stats.iteration++;
	    frontier_attribute->queue_index++;   	   
	    frontier_attribute->selector ^= 1;

            if (retval = work_progress->GetQueueLength(
                frontier_attribute->queue_index,
                frontier_attribute->queue_length)) break;
	    
	 /*   mgpu::SegReduceCsr(data_slice->d_c_set, 
			       data_slice->d_temp_keys, 
			       data_slice->nodes_query * data_slice->nodes_data,
			       data_slice->nodes_query,
			       false,
			       data_slice->d_temp_keys,
			       (int)0,
			       mgpu::plus<int>(),
			       context);
	*/
	    //TODO: Divide the results by hop number of query nodes
	   /* util::MemsetDivideVectorKernel<<<128,128>>>(data_slice->d_temp_keys, 
							data_slice->d_query_degrees,
							data_slice->nodes_query);

	    gunrock::oprtr::advance::LaunchKernel<AdvanceKernelPolicy, SMProblem, EdgeWeightFunctor>(
		d_done,
		enactor_stats,
		frontier_attribute,
		data_slice,
		(VertexId*)NULL,
		(bool*)NULL,
		(bool*)NULL,
		d_scanned_edges,
		graph_slice->frontier_queues.d_keys[frontier_attribute.selector],
          	graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
          	(VertexId*)NULL,
	        (VertexId*)NULL,
        	graph_slice->d_row_offsets,
	        graph_slice->d_column_indices,
	        (SizeT*)NULL,
        	(VertexId*)NULL,
	        graph_slice->frontier_elements[frontier_attribute.selector],
        	graph_slice->frontier_elements[frontier_attribute.selector^1],
	        this->work_progress,
        	context,
	        gunrock::oprtr::advance::V2V);

	    //TODO: Potential bitonic sorter under util::sorter
	    mgpu::LocalitySortPairs(data_slice->d_edge_weights,
				    data_slice->d_edge_labels, data_slice->edges_query, context);

*/
	    /*mgpu::LocalitySortPairs(data_slice->d_temp_keys,
	   			    data_slice->d_query_nodeIDs,
				    data_slice->nodes_query,
				    context);
	   */
/*	    oprtr::advance::LaunchKernel
		  <AdvanceKernelPolicy, Problem, PruneFunctor>(
                  d_done,
                  enactor_stats,
                  frontier_attribute,
                  data_slice,
                  (VertexId*)NULL,
                  (bool*)NULL,
                  (bool*)NULL,
                  d_scanned_edges,
                  graph_slice->frontier_queues.d_keys[frontier_attribute.selector],
                  graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
                  (VertexId*)NULL,
                  (VertexId*)NULL,
                  graph_slice->d_query_row,
                  graph_slice->d_query_col,
                  (SizeT*)NULL,
                  (VertexId*)NULL,
                  graph_slice->frontier_elements[frontier_attribute.selector],
                  graph_slice->frontier_elements[frontier_attribute.selector^1],
                  this->work_progress,
                  context,
                  gunrock::oprtr::advance::V2V);		
*/
	oprtr::advance::LaunchKernel<AdvanceKernelPolicy, Problem, PruneFunctor>(
                enactor_stats[0],
                frontier_attribute[0],
                d_data_slice,
                (VertexId*)NULL,
                (bool*    )NULL,
                (bool*    )NULL,
                d_scanned_edges,
                frontier_queue->keys[frontier_attribute->selector  ].GetPointer(util::DEVICE),
                frontier_queue->keys[frontier_attribute->selector^1].GetPointer(util::DEVICE),
                (VertexId*)NULL,
                (VertexId*)NULL,
                graph_slice->row_offsets   .GetPointer(util::DEVICE),
                graph_slice->column_indices.GetPointer(util::DEVICE),
                (SizeT*   )NULL,
                (VertexId*)NULL,
                graph_slice->nodes,
                graph_slice->edges,
                work_progress[0],
                context[0],
                stream,
                gunrock::oprtr::advance::V2V);

	   if (DEBUG && (retval = util::GRError(cudaDeviceSynchronize(),
          	"Advance::LaunchKernel failed", __FILE__, __LINE__))) break;

	   frontier_attribute->queue_index++;

           if (true) {
                if (retval = work_progress->GetQueueLength(
                        frontier_attribute->queue_index,
                        frontier_attribute->queue_length)) break;
                printf("advance queue length: %lld",
                       (long long) frontier_attribute->queue_length);
            }

            // TODO: extract graph with proper format (edge list, csr, etc.)

            if (d_scanned_edges) cudaFree(d_scanned_edges);

        } while (0);

        if (DEBUG) {
            printf("\nGPU Primitive Enact Done.\n");
        }

        return retval;
    }

    /**
     * \addtogroup PublicInterface
     * @{
     */

    /**
     * @brief Primitive enact kernel entry.
     *
     * @tparam Problem Problem type. @see Problem
     *
     * @param[in] context CudaContext pointer for ModernGPU APIs
     * @param[in] problem Pointer to Problem object.
     * @param[in] max_grid_size Max grid size for kernel calls.
     * @param[in] traversal_mode Traversal Mode for advance operator:
     *            Load-balanced or Dynamic cooperative
     *
     * \return cudaError_t object indicates the success of all CUDA functions.
     */
    template <typename SMProblem>
    cudaError_t Enact(
        ContextPtr  context,
        SMProblem*  problem,
        int         max_grid_size  = 0) {
	
	int min_sm_version = -1;
        for (int i = 0; i < this->num_gpus; i++) {
            if (min_sm_version == -1 ||
                this->cuda_props[i].device_sm_version < min_sm_version) {
                min_sm_version = this->cuda_props[i].device_sm_version;
            }
        }

        if (min_sm_version >= 300) {
            typedef oprtr::filter::KernelPolicy <
                Problem,             // Problem data type
                300,                 // CUDA_ARCH
                INSTRUMENT,          // INSTRUMENT
                0,                   // SATURATION QUIT
                true,                // DEQUEUE_PROBLEM_SIZE
                8,                   // MIN_CTA_OCCUPANCY
                8,                   // LOG_THREADS
                1,                   // LOG_LOAD_VEC_SIZE
                0,                   // LOG_LOADS_PER_TILE
                5,                   // LOG_RAKING_THREADS
                5,                   // END_BITMASK_CULL
                8 >                  // LOG_SCHEDULE_GRANULARITY
                FilterPolicy;

            typedef oprtr::advance::KernelPolicy <
                Problem,             // Problem data type
                300,                 // CUDA_ARCH
                INSTRUMENT,          // INSTRUMENT
                1,                   // MIN_CTA_OCCUPANCY
                10,                  // LOG_THREADS
                8,                   // LOG_BLOCKS
                32 * 128,            // LIGHT_EDGE_THRESHOLD (used for LB)
                1,                   // LOG_LOAD_VEC_SIZE
                0,                   // LOG_LOADS_PER_TILE
                5,                   // LOG_RAKING_THREADS
                32,                  // WARP_GATHER_THRESHOLD
                128 * 4,             // CTA_GATHER_THRESHOLD
                7,                   // LOG_SCHEDULE_GRANULARITY
                oprtr::advance::LB >
                AdvancePolicy;

                return EnactSM<
                    AdvancePolicy, FilterPolicy, Problem>(
                        context, problem, max_grid_size);
        }

        // to reduce compile time, get rid of other architecture for now
        // TODO: add all the kernel policy setting for all architectures

        printf("Not yet tuned for this architecture\n");
        return cudaErrorInvalidDeviceFunction;
    }

    /** @} */
};

}  // namespace sm
}  // namespace app
}  // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End: