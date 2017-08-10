/*
 * IndexComputer.cpp
 *
 *  Created on: 21 Jul 2016
 *      Author: Zeyi Wen
 *		@brief: compute index for each feature value in the feature lists
 */

#include <cuda.h>
#include <vector>
#include <algorithm>
#include <helper_cuda.h>
#include <thrust/scan.h>
#include <thrust/execution_policy.h>
#include "IndexComputer.h"
#include "../Hashing.h"
#include "../Bagging/BagManager.h"
#include "../Memory/gbdtGPUMemManager.h"
#include "../../SharedUtility/CudaMacro.h"
#include "../../SharedUtility/KernelConf.h"
#include "../../SharedUtility/powerOfTwo.h"
#include "../../SharedUtility/HostUtility.h"
#include "../../SharedUtility/binarySearch.h"
#include "../../SharedUtility/setSegmentKey.h"

using std::vector;

int IndexComputer::m_totalFeaValue = -1;//total number of feature values in the whole dataset
int IndexComputer::m_numFea = -1;	//number of features
int IndexComputer::m_maxNumofSN = -1;
long long IndexComputer::m_total_copy = -1;

unsigned char *IndexComputer::pPartitionMarker = NULL;
uint *IndexComputer::m_pnKey = NULL;

//histogram based partitioning
uint *IndexComputer::m_pHistogram_d = NULL;
uint IndexComputer::m_numElementEachThd = LARGE_4B_UINT;
uint IndexComputer::m_totalNumEffectiveThd = LARGE_4B_UINT;
uint *IndexComputer::m_pEachNodeStartPos_d;

/**
  *@brief: mark feature values beloning to node with id=snId by 1
  */
__global__ void MarkPartition(int preMaxNid, int *pFvToInsId, int *pInsIdToNodeId,
							int totalNumFv, unsigned char *pParitionMarker){
	int gTid = GLOBAL_TID();
	if(gTid >= totalNumFv)//thread has nothing to mark; note that "totalNumFv" will not decrease!
		return;

	uint insId = pFvToInsId[gTid];
	int nid = pInsIdToNodeId[insId];
	if(nid <= preMaxNid){//instance in leaf node
		pParitionMarker[gTid] = 0xff;//can only support 8 level trees
		return;
	}
	int partitionId = nid - preMaxNid - 1;
	ECHECKER(partitionId);
	pParitionMarker[gTid] = partitionId;
}

/**
 * @brief: count number of elements in each segment in the partition marker
 */
__global__ void PartitionHistogram(unsigned char *pPartitionMarker, uint markerLen, uint numParition,
								   uint numEleEachThd, uint totalNumThd, uint *pHistogram_d){
	extern __shared__ uint counters[];
	int gTid = GLOBAL_TID();
	uint tid = threadIdx.x;
	for(int p = 0; p < numParition; p++){
		counters[tid * numParition + p] = 0;
	}
	if(gTid >= totalNumThd){//thread has nothing to do
		return;
	}
	for(int i = 0; i < numEleEachThd; i++){
		if(gTid * numEleEachThd + i >= markerLen){//no element to process
			break;
		}
		int pid = pPartitionMarker[gTid * numEleEachThd + i];
		if(pid >= numParition)//this is possible, because some elements are "marked" as leaves.
			continue;//skip this element
		counters[tid * numParition + pid]++;
	}
	//store counters to global memory
	for(int p = 0; p < numParition; p++){
		//counters of the same partition are consecutive
		pHistogram_d[p * totalNumThd + gTid] = counters[tid * numParition + p];
	}
}

__global__ void ComputeNumFvalueEachNode(const uint *pHistogram_d, uint totalNumThd, uint *pNumFeaValueEachSN){
	//update number of feature values of each new node
	pNumFeaValueEachSN[threadIdx.x] = pHistogram_d[threadIdx.x * totalNumThd + totalNumThd - 1];
}

/**
  * @brief: store gather indices
  */
__global__ void CollectGatherIdx(const unsigned char *pPartitionMarker, uint markerLen,
								 const uint *pHistogram_d, uint *pEachNodeStartPos_d, uint numParition,
								 uint numEleEachThd, uint totalNumThd, uint *pGatherIdx){
	int gTid = GLOBAL_TID();
	if(gTid >= totalNumThd)//thread has nothing to collect
		return;

	uint tid = threadIdx.x;
	extern __shared__ uint eleDst[];//effectively, 4 counters for each thread

	//write start pos of each thread
	for(int p = 0; p < numParition; p++){
		uint thdCounterPos = p * totalNumThd + gTid;
		uint partitionStartPos = pEachNodeStartPos_d[p];//partition start pos
		if(gTid > 0)
			partitionStartPos += pHistogram_d[thdCounterPos - 1];

		eleDst[tid * numParition + p] = partitionStartPos;
	}

	for(int i = 0; i < numEleEachThd; i++){
		uint elePos = gTid * numEleEachThd + i;
		if(elePos >= markerLen)//no element to process
			return;
		int pid = pPartitionMarker[elePos];
		if(pid >= numParition){
			pGatherIdx[elePos] = LARGE_4B_UINT;
			continue;//skip this element, as element is marked as leaf.
		}
		uint writeIdx = tid * numParition + pid;
		pGatherIdx[elePos] = eleDst[writeIdx];//element destination ###### can be improved by shared memory
		eleDst[writeIdx]++;
	}
}

/**
  * @brief: store gather indices
  */
__global__ void EachFeaLenEachNode(const unsigned char *pPartitionMarker, uint markerLen,
								 int *pEachFeaLenEachNode, uint numFea,
								 uint numParition, uint *pEachFeaStart){
	int gTid = GLOBAL_TID();
	if(gTid >= markerLen)//thread has nothing to collect
		return;

	int pid = pPartitionMarker[gTid];
	if(pid >= numParition){
		return;//skip this element, as element is marked as leaf.
	}
	uint feaId;
	RangeBinarySearch(gTid, pEachFeaStart, numFea, feaId);
	atomicAdd(&pEachFeaLenEachNode[pid * numFea + feaId], 1);
}

/**
  * @brief: compute gether index by GPUs
  */
void IndexComputer::ComputeIdxGPU(int numSNode, int maxNumSN, int bagId){
	PROCESS_ERROR(m_totalFeaValue > 0 && numSNode > 0 && maxNumSN >= 0);
	
	BagManager bagManager;
	GBDTGPUMemManager manager;
	KernelConf conf;
	int blockSizeForFvalue;
	dim3 dimNumofBlockForFvalue;
	conf.ConfKernel(m_totalFeaValue, blockSizeForFvalue, dimNumofBlockForFvalue);

	int *pTmpInsIdToNodeId = bagManager.m_pInsIdToNodeIdEachBag + bagId * bagManager.m_numIns;
	MarkPartition<<<dimNumofBlockForFvalue, blockSizeForFvalue>>>(bagManager.m_pPreMaxNid_h[bagId], manager.m_pDInsId, pTmpInsIdToNodeId,
																  m_totalFeaValue, pPartitionMarker);
	GETERROR("after MarkPartition");

	dim3 numBlkDim;
	int numThdPerBlk;
	conf.ConfKernel(m_totalNumEffectiveThd, numThdPerBlk, numBlkDim);
	PartitionHistogram<<<numBlkDim, numThdPerBlk, numSNode * numThdPerBlk * sizeof(uint)>>>(pPartitionMarker, m_totalFeaValue, numSNode,
																	     	 m_numElementEachThd, m_totalNumEffectiveThd, m_pHistogram_d);
	GETERROR("after PartitionHistogram");
	//compute prefix sum for one array
	thrust::inclusive_scan_by_key(thrust::system::cuda::par, m_pnKey, m_pnKey + m_totalNumEffectiveThd * numSNode,
								  m_pHistogram_d, m_pHistogram_d);//in place prefix sum

	//get number of fvalue in each partition (i.e. each new node)
	uint *pTempNumFvalueEachNode = bagManager.m_pNumFvalueEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable;
	ComputeNumFvalueEachNode<<<1, numSNode>>>(m_pHistogram_d, m_totalNumEffectiveThd, pTempNumFvalueEachNode);
	cudaDeviceSynchronize();//this is very important

	checkCudaErrors(cudaMemcpy(m_pEachNodeStartPos_d, pTempNumFvalueEachNode, sizeof(uint) * numSNode, cudaMemcpyDeviceToDevice));
	thrust::exclusive_scan(thrust::system::cuda::par, m_pEachNodeStartPos_d, m_pEachNodeStartPos_d + numSNode, m_pEachNodeStartPos_d);

	//write to gather index
	uint *pTmpGatherIdx = bagManager.m_pIndicesEachBag_d + bagId * bagManager.m_numFeaValue;
	int flags = -1;//all bits are 1
	checkCudaErrors(cudaMemset(pTmpGatherIdx, flags, sizeof(uint) * m_totalFeaValue));//when leaves appear, this is effective.
	CollectGatherIdx<<<numBlkDim, numThdPerBlk, numSNode * numThdPerBlk * sizeof(uint)>>>(pPartitionMarker, m_totalFeaValue,
												  m_pHistogram_d, m_pEachNodeStartPos_d, numSNode,
												  m_numElementEachThd, m_totalNumEffectiveThd, pTmpGatherIdx);
	GETERROR("after CollectGatherIdx");

	uint *pTmpFvalueStartPosEachNode = bagManager.m_pFvalueStartPosEachNodeEachBag_d + bagId * bagManager.m_maxNumSplittable;
	//compute each feature length and start position in each node
	int *pTmpEachFeaLenEachNode = bagManager.m_pEachFeaLenEachNodeEachBag_d +
								  bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea;
	uint * pTmpEachFeaStartPosEachNode = bagManager.m_pEachFeaStartPosEachNodeEachBag_d +
											  bagId * bagManager.m_maxNumSplittable * bagManager.m_numFea;

	checkCudaErrors(cudaMemset(pTmpEachFeaLenEachNode, 0, sizeof(int) * bagManager.m_maxNumSplittable * m_numFea));
	EachFeaLenEachNode<<<dimNumofBlockForFvalue, blockSizeForFvalue>>>(pPartitionMarker, m_totalFeaValue, pTmpEachFeaLenEachNode,
																	   m_numFea, numSNode, manager.m_pFeaStartPos);
	thrust::exclusive_scan(thrust::system::cuda::par, pTmpEachFeaLenEachNode, pTmpEachFeaLenEachNode + m_numFea * numSNode, pTmpEachFeaStartPosEachNode);
	
	//get feature values start position of each new node
	checkCudaErrors(cudaMemcpy(pTmpFvalueStartPosEachNode, m_pEachNodeStartPos_d, sizeof(uint) * numSNode, cudaMemcpyDeviceToDevice));
}

/**
 * @brief: allocate reusable memory
 */
void IndexComputer::AllocMem(int nNumofFeatures, int curNumSN, int maxNumSN)
{
	m_numFea = nNumofFeatures;
	m_maxNumofSN = maxNumSN;
	if(m_pnKey == NULL){
		//histogram based partitioning
		m_numElementEachThd = 16;
		if(m_maxNumofSN > m_numElementEachThd)
			m_numElementEachThd = m_maxNumofSN;//make sure the memory usage is the same as the training data set
		m_totalNumEffectiveThd = Ceil(m_totalFeaValue, m_numElementEachThd);

		checkCudaErrors(cudaMalloc((void**)&pPartitionMarker, sizeof(unsigned char) * m_totalFeaValue));
		uint totalMemSize =  sizeof(uint) * m_maxNumofSN * m_totalNumEffectiveThd * 2;
		checkCudaErrors(cudaMalloc((void**)&m_pHistogram_d, totalMemSize));
		m_pnKey = m_pHistogram_d + m_maxNumofSN * m_totalNumEffectiveThd;
		checkCudaErrors(cudaMalloc((void**)&m_pEachNodeStartPos_d, sizeof(uint) * m_maxNumofSN));
	}

	dim3 dimNumofBlockToSetKey;
	dimNumofBlockToSetKey.y = curNumSN;
	uint blockSize = 128;
	dimNumofBlockToSetKey.x = (m_totalNumEffectiveThd + blockSize - 1) / blockSize;
	SetKey<<<dimNumofBlockToSetKey, blockSize>>>(m_totalNumEffectiveThd, m_pnKey);
}

//free memory
void IndexComputer::FreeMem()
{
//	checkCudaErrors(cudaFree(pPartitionMarker));
//	//histogram based partitioning
//	checkCudaErrors(cudaFree(m_pHistogram_d));
//	checkCudaErrors(cudaFree(m_pnKey));
//	checkCudaErrors(cudaFree(m_pEachNodeStartPos_d));
}
